import Foundation

/// A bounded JSON-RPC identifier used only to cancel work within the authenticated grant.
public enum MCPRequestIdentifier: Hashable, Sendable {
  case string(String)
  case integer(Int)
}

struct MCPActiveQuery: Sendable {
  let requestID: MCPRequestIdentifier?
  let cancel: @Sendable () -> Void
  let wait: @Sendable () async -> Void
}

struct MCPQueryAuthorization: Sendable {
  let context: MCPAuthorizationContext
  let scope: MCPReadScope
  let profileID: UUID?
  let requestID: MCPRequestIdentifier?
  let endpointOwner: UUID?
}

extension MCPGrantStore {
  /// Runs an authorized operation with a four-query grant cap and a 15-second deadline.
  ///
  /// The context, required scope and optional profile are validated before and after execution.
  /// Request identity enables grant-bound cancellation; endpoint ownership prevents stale listener responses.
  /// - Throws: on invalid authorization, overload, timeout, cancellation or operation failure.
  /// Underlying work is cancelled and awaited before returning.
  /// - Parameters:
  ///   - context: Previously authenticated credential, revalidated before and after the operation.
  ///   - scope: Permission required by the deliberately registered tool.
  ///   - profileID: Authorized explicit profile, or nil for profile-independent tools.
  ///   - requestID: Optional JSON-RPC identity for cancellation within this grant.
  ///   - endpointOwner: Listener generation; nil only for direct execution without a listener.
  ///   - operation: Read-only work that cooperates with cancellation.
  public func execute<Result: Sendable>(
    context: MCPAuthorizationContext,
    scope: MCPReadScope,
    profileID: UUID?,
    requestID: MCPRequestIdentifier? = nil,
    endpointOwner: UUID? = nil,
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    let authorization = MCPQueryAuthorization(
      context: context,
      scope: scope,
      profileID: profileID,
      requestID: requestID,
      endpointOwner: endpointOwner
    )
    return try await execute(
      authorization: authorization,
      waitForDeadline: { try await Task.sleep(for: .seconds(15)) },
      operation: operation
    )
  }

  func execute<Result: Sendable>(
    authorization: MCPQueryAuthorization,
    waitForDeadline: @escaping @Sendable () async throws -> Void,
    beforeValidation: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    let context = authorization.context
    try validate(context, scope: authorization.scope, profileID: authorization.profileID)
    try Task.checkCancellation()
    try validateEndpoint(owner: authorization.endpointOwner)
    guard (activeQueries[context.grantID]?.count ?? 0) < 4 else {
      throw MCPAccessFailure.queryLimit
    }
    let identifier = UUID()
    let task = Task {
      defer { finishQuery(grantID: context.grantID, id: identifier) }
      return try await MCPQueryDeadline.run(waitForDeadline: waitForDeadline, operation: operation)
    }
    activeQueries[context.grantID, default: [:]][identifier] = MCPActiveQuery(
      requestID: authorization.requestID,
      cancel: { task.cancel() },
      wait: { _ = await task.result }
    )
    let result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    await beforeValidation()
    try Task.checkCancellation()
    try validateResponse(context, owner: authorization.endpointOwner)
    try validate(context, scope: authorization.scope, profileID: authorization.profileID)
    return result
  }

  /// Cancels matching active requests within the current credential and endpoint generation.
  /// - Throws: if the context or endpoint is stale; never cancels another credential’s work.
  public func cancel(
    context: MCPAuthorizationContext,
    requestID: MCPRequestIdentifier,
    endpointOwner: UUID? = nil
  ) throws {
    try validateResponse(context, owner: endpointOwner)
    for query in activeQueries[context.grantID]?.values ?? [:].values
    where query.requestID == requestID {
      query.cancel()
    }
  }

  func validateEndpoint(owner: UUID?) throws {
    guard acceptingQueries, endpointOwner == owner else { throw MCPAccessFailure.unavailable }
  }

  func validateResponse(_ context: MCPAuthorizationContext, owner: UUID?) throws {
    try validateEndpoint(owner: owner)
    try validate(context)
  }

  /// Endpoint ownership remains reserved through draining. A stale end can never suspend
  /// a new owner, including when two cancellation paths end the same old generation.
  func beginEndpoint() throws -> UUID {
    guard endpointOwner == nil else { throw MCPAccessFailure.unavailable }
    let owner = UUID()
    endpointOwner = owner
    acceptingQueries = true
    return owner
  }

  func endEndpoint(owner: UUID) async {
    guard endpointOwner == owner else { return }
    await suspendQueries()
    guard endpointOwner == owner else { return }
    endpointOwner = nil
  }

  func suspendQueries() async {
    acceptingQueries = false
    let captured = activeQueries
    let queries = captured.values.flatMap { $0.values }
    for query in queries { query.cancel() }
    for query in queries { await query.wait() }
    // Each owned child removes its slot before completing. Defensively remove only
    // captured IDs as well; duplicate shutdown paths cannot erase another generation.
    for (grantID, entries) in captured {
      for id in entries.keys { activeQueries[grantID]?.removeValue(forKey: id) }
      if activeQueries[grantID]?.isEmpty == true { activeQueries.removeValue(forKey: grantID) }
    }
  }

  func resumeQueries() { acceptingQueries = true }

  private func finishQuery(grantID: UUID, id: UUID) {
    activeQueries[grantID]?.removeValue(forKey: id)
    if activeQueries[grantID]?.isEmpty == true { activeQueries.removeValue(forKey: grantID) }
  }

  func cancelQueries(grantID: UUID) {
    for query in activeQueries[grantID]?.values ?? [:].values { query.cancel() }
  }
}

enum MCPQueryDeadline {
  /// Structured children must finish cancellation before a query slot/lease can be released.
  @concurrent
  static func run<Result: Sendable>(
    waitForDeadline: @escaping @Sendable () async throws -> Void,
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await waitForDeadline()
        throw MCPAccessFailure.queryTimeout
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CancellationError() }
      return result
    }
  }
}
