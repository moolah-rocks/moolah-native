import Foundation
import Hummingbird
import MCP

/// HTTP only. The bind address is deliberately not configurable.
public struct MCPLoopbackHost: Sendable {
  /// Hard cap for either HTTP body, independent of tool page limits.
  public static let maximumBodyBytes = 1_048_576
  /// Validated port and exact browser-origin rules.
  public let policy: MCPRequestPolicy

  /// Creates an inert host; construction opens no socket.
  /// - Parameter policy: Validated local endpoint settings.
  public init(policy: MCPRequestPolicy) {
    self.policy = policy
  }

  /// Listens on 127.0.0.1 until cancelled; throws on bind failure and never changes ports.
  /// - Parameters:
  ///   - authorize: Checks every request before its body is collected. Never log its headers.
  ///   - respond: Handles authenticated messages off the UI actor, with per-call grants.
  ///   - onRunning: Reports successful binding, without financial data or credentials.
  /// - Throws: Bind failures or cancellation. Socket lifetime belongs to this async call.
  public func run(
    authorize: @escaping @Sendable (MCP.HTTPRequest) async -> Bool,
    respond: @escaping @Sendable (MCP.HTTPRequest) async throws -> MCP.HTTPResponse,
    onRunning: @escaping @Sendable () async -> Void = {}
  ) async throws {
    try await run(
      checkAccess: { request in
        await authorize(request)
          ? nil
          : .error(
            statusCode: 401,
            .invalidRequest("Authentication required"),
            extraHeaders: ["WWW-Authenticate": "Bearer"]
          )
      },
      respond: respond,
      onRunning: onRunning
    )
  }

  /// Authentication/overload checks run before body collection, with generic HTTP rejections.
  public func run(
    checkAccess: @escaping @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse?,
    respond: @escaping @Sendable (MCP.HTTPRequest) async throws -> MCP.HTTPResponse,
    onRunning: @escaping @Sendable () async -> Void = {}
  ) async throws {
    let router = Router()
    router.add(
      middleware: MCPHTTPMiddleware(
        policy: policy,
        checkAccess: checkAccess,
        respond: respond
      )
    )
    let application = Application(
      router: router,
      server: .init { MCPHTTP1Channel(responder: $0) },
      configuration: .init(
        address: .hostname("127.0.0.1", port: policy.port),
        backlog: 32,
        // Rebind after an app restart while old accepted connections remain in TIME_WAIT.
        // This is SO_REUSEADDR, not SO_REUSEPORT: a live listener still owns the endpoint.
        reuseAddress: true,
        availableConnectionsDelegate: .maximum(32, logger: .init(label: "Moolah.MCP"))
      ),
      onServerRunning: { _ in await onRunning() }
    )
    try await application.run()
  }
}
