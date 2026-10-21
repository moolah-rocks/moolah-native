import Foundation
import MCP

/// An inert, manually authenticated Streamable HTTP endpoint. Only run() opens a socket.
public struct MCPAuthenticatedEndpoint: Sendable {
  let host: MCPLoopbackHost
  let grants: MCPGrantStore
  let tools: [String: MCPAuthorizedTool]

  /// Configures an inert loopback endpoint with explicit grants and registered read tools.
  /// - Throws: invalidTool for duplicate, oversized or invalid tool registrations. No socket is opened.
  /// - Parameters:
  ///   - policy: Validated fixed loopback port and explicit browser-origin policy.
  ///   - grants: Device-local credential authority shared by this endpoint.
  ///   - tools: At most sixteen unique, explicitly registered read tools.
  public init(
    policy: MCPRequestPolicy,
    grants: MCPGrantStore,
    tools: [MCPAuthorizedTool]
  ) throws {
    guard tools.count <= 16, Set(tools.map(\.schema.name)).count == tools.count,
      tools.allSatisfy({
        $0.schema.name.hasPrefix("moolah_") && $0.schema.name.utf8.count <= 80
          && ($0.requiresProfile || $0.scope == .profiles) && $0.scope != .transactionNotes
      })
    else { throw MCPConfigurationError.invalidTool }
    self.host = MCPLoopbackHost(policy: policy)
    self.grants = grants
    self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.schema.name, $0) })
  }

  /// Runs one exclusive listener generation until cancelled or the host fails.
  /// Calls onRunning after binding; cancellation drains HTTP work and all grant queries.
  /// - Throws: on bind, configuration or lifecycle failures. Await completion before restarting.
  @concurrent
  public func run(onRunning: @escaping @Sendable () async -> Void = {}) async throws {
    let owner = try await grants.beginEndpoint()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await host.run(
            checkAccess: { request in await admission(request, owner: owner) },
            respond: { request in try await respond(request, owner: owner) },
            onRunning: onRunning
          )
        }
        // Structured cancellation starts query cleanup while the HTTP host drains sockets.
        group.addTask {
          do {
            while true { try await Task.sleep(for: .seconds(86400)) }
          } catch {
            await grants.endEndpoint(owner: owner)
            throw error
          }
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
      await grants.endEndpoint(owner: owner)
    } catch {
      await grants.endEndpoint(owner: owner)
      throw error
    }
  }

  func admission(_ request: HTTPRequest, owner: UUID? = nil) async -> HTTPResponse? {
    do {
      try await grants.validateEndpoint(owner: owner)
      guard
        try await grants.admit(header: request.header("Authorization"), endpointOwner: owner) != nil
      else {
        return Self.unauthorized
      }
      return nil
    } catch MCPAccessFailure.rateLimited {
      return HTTPResponse.error(
        statusCode: 429,
        .internalError("Too many requests"),
        extraHeaders: ["Retry-After": "60", "Cache-Control": "no-store"]
      )
    } catch {
      return HTTPResponse.error(
        statusCode: 503,
        .internalError("Service unavailable"),
        extraHeaders: ["Cache-Control": "no-store"]
      )
    }
  }

  func respond(_ request: HTTPRequest, owner: UUID? = nil) async throws -> HTTPResponse {
    guard let context = try await grants.authenticate(header: request.header("Authorization"))
    else {
      return Self.unauthorized
    }
    do {
      try await grants.validateResponse(context, owner: owner)
    } catch {
      return .error(statusCode: 503, .internalError("Service unavailable"))
    }
    let envelope = request.body.flatMap {
      try? JSONDecoder().decode([String: Value].self, from: $0)
    }
    let requestID = Self.identifier(envelope?["id"])
    let visible = tools.values.filter { context.scopes.contains($0.scope) }.map(\.schema)
      .sorted { $0.name < $1.name }
    let response = try await MCPProtocolAdapter.respond(
      to: request,
      tools: visible,
      deadline: .seconds(16)
    ) { parameters in
      await call(parameters, context: context, requestID: requestID, owner: owner)
    }
    if response.statusCode == 202, envelope?["method"] == .string("notifications/cancelled"),
      case .object(let parameters) = envelope?["params"],
      let identifier = Self.identifier(parameters["requestId"])
    {
      try await grants.cancel(context: context, requestID: identifier, endpointOwner: owner)
    }
    do {
      try await grants.validateResponse(context, owner: owner)
      try Task.checkCancellation()
      return response
    } catch is CancellationError {
      throw CancellationError()
    } catch MCPAccessFailure.unavailable {
      return .error(statusCode: 503, .internalError("Service unavailable"))
    } catch {
      return Self.unauthorized
    }
  }
}

extension MCPAuthenticatedEndpoint {
  private func call(
    _ parameters: CallTool.Parameters,
    context: MCPAuthorizationContext,
    requestID: MCPRequestIdentifier?,
    owner: UUID?
  ) async -> CallTool.Result {
    do {
      guard let tool = tools[parameters.name] else { throw MCPAccessFailure.accessDenied }
      try await grants.validate(context, scope: tool.scope)
      let arguments = parameters.arguments ?? [:]
      let profileID = try Self.profileID(arguments, required: tool.requiresProfile)
      return try await grants.execute(
        context: context,
        scope: tool.scope,
        profileID: profileID,
        requestID: requestID,
        endpointOwner: owner
      ) {
        let invocation = MCPToolInvocation(
          context: context,
          profileID: profileID,
          arguments: arguments
        )
        let result = try await tool.handler(invocation)
        guard try JSONEncoder().encode(result).count <= MCPLoopbackHost.maximumBodyBytes - 4096
        else {
          throw MCPAccessFailure.resultTooLarge
        }
        return result
      }
    } catch let failure as MCPAccessFailure {
      return failure.result()
    } catch is CancellationError {
      return MCPAccessFailure.queryCancelled.result()
    } catch {
      return MCPAccessFailure.internalFailure.result()
    }
  }

  private static func profileID(_ arguments: [String: Value], required: Bool) throws -> UUID? {
    guard required else { return nil }
    guard let value = arguments["profile_id"]?.stringValue, let id = UUID(uuidString: value) else {
      throw MCPAccessFailure.invalidFilter
    }
    return id
  }

  private static func identifier(_ value: Value?) -> MCPRequestIdentifier? {
    switch value {
    case .string(let string) where string.utf8.count <= 128: .string(string)
    case .int(let integer): .integer(integer)
    default: nil
    }
  }

  private static var unauthorized: HTTPResponse {
    .error(
      statusCode: 401,
      .invalidRequest("Authentication required"),
      extraHeaders: ["WWW-Authenticate": "Bearer", "Cache-Control": "no-store"]
    )
  }
}
