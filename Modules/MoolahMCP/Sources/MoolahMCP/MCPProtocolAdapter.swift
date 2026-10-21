import Foundation
import MCP

/// A fresh SDK transport per HTTP message isolates client-selected JSON-RPC IDs.
/// Stateless requests carry their authorization in the handler closures, never global SDK state.
public enum MCPProtocolAdapter {
  /// Processes one stateless Streamable HTTP message using an isolated SDK server.
  /// - Parameters:
  ///   - request: An authenticated request that passed endpoint and size checks.
  ///   - tools: Only the implemented tools visible to the current grant.
  ///   - deadline: Maximum processing time; tool cleanup is awaited after expiry.
  ///   - call: Authorized, cooperative tool work; errors must already be safe to disclose.
  /// - Returns: The SDK's JSON/202/405 response, or a generic deadline error.
  /// - Throws: Cancellation after stopping and awaiting tool work.
  public static func respond(
    to request: HTTPRequest,
    tools: [Tool] = [],
    deadline: Duration = .seconds(15),
    call: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result = { _ in
      throw MCPError.invalidParams("Unknown tool")
    }
  ) async throws -> HTTPResponse {
    try await respond(
      to: request,
      tools: tools,
      waitForDeadline: { try await Task.sleep(for: deadline) },
      call: call
    )
  }

  static func respond(
    to request: HTTPRequest,
    tools: [Tool] = [],
    waitForDeadline: @escaping @Sendable () async throws -> Void,
    call: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
  ) async throws -> HTTPResponse {
    if request.method == "POST", !isValidMessage(request.body) {
      return .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC message"))
    }
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        AcceptHeaderValidator(mode: .jsonOnly),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
      ])
    )
    let server = Server(
      name: "Moolah",
      version: "1",
      capabilities: .init(tools: .init(listChanged: false))
    )
    let execution = MCPRequestExecution()
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
    await server.withMethodHandler(CallTool.self) { parameters in
      try await execution.run(parameters, call: call)
    }
    try await server.start(transport: transport)
    do {
      let response = try await response(
        to: request,
        transport: transport,
        waitForDeadline: waitForDeadline
      )
      try Task.checkCancellation()
      await execution.cancelAndWait()
      await server.stop()
      return response
    } catch {
      await execution.cancelAndWait()
      await server.stop()
      throw error
    }
  }
}

extension MCPProtocolAdapter {
  private static func response(
    to request: HTTPRequest,
    transport: StatelessHTTPServerTransport,
    waitForDeadline: @escaping @Sendable () async throws -> Void
  ) async throws -> HTTPResponse {
    try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
      group.addTask {
        await withTaskCancellationHandler {
          await transport.handleRequest(request)
        } onCancel: {
          Task { await transport.disconnect() }
        }
      }
      group.addTask {
        try await waitForDeadline()
        return .error(statusCode: 504, .internalError("Request timed out"))
      }
      defer { group.cancelAll() }
      let response = try await group.next() ?? .error(statusCode: 503, .connectionClosed)
      await transport.disconnect()
      return response
    }
  }

  private static func isValidMessage(_ body: Data?) -> Bool {
    guard let body,
      let value = try? JSONDecoder().decode([String: Value].self, from: body),
      value["jsonrpc"] == .string("2.0"),
      let method = value["method"]?.stringValue, !method.isEmpty
    else { return false }
    guard let identifier = value["id"] else { return true }
    switch identifier {
    case .string(let value): return value.utf8.count <= 128
    case .int: return true
    default: return false
    }
  }
}
