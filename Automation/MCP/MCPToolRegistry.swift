import Foundation
import MoolahMCP

/// Sendable transport boundary: validates permissions before any profile/entity resolution.
struct MCPToolRegistry: Sendable {
  let service: MoolahReadQueryService
  let grants: MCPGrantStore
  let cursors: MCPCursorSigner
  let now: @Sendable () -> Date
  let currentTimeZone: @Sendable () -> TimeZone

  init(
    service: MoolahReadQueryService,
    grants: MCPGrantStore,
    now: @escaping @Sendable () -> Date = { Date() },
    currentTimeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) throws {
    self.service = service
    self.grants = grants
    self.cursors = try MCPCursorSigner()
    self.now = now
    self.currentTimeZone = currentTimeZone
  }

  var tools: [MCPAuthorizedTool] {
    MCPToolDefinition.allCases.map { definition in
      MCPAuthorizedTool(
        schema: MCPToolSchemas.schema(for: definition),
        scope: definition.scope,
        requiresProfile: definition != .profiles
      ) { invocation in
        try await call(definition, context: invocation.context, arguments: invocation.arguments)
      }
    }
  }

  @concurrent
  func call(
    _ tool: MCPToolDefinition,
    context: MCPAuthorizationContext,
    arguments: [String: MCPToolValue]
  ) async throws -> MCPToolResult {
    do {
      try await grants.validate(context, scope: tool.scope)
      let input = MCPToolArguments(values: arguments)
      try input.validateKeys(tool.argumentKeys)
      let zone = try input.timeZone(default: currentTimeZone())
      if tool == .profiles { return try await profiles(context: context, timeZone: zone) }
      let id = try input.uuid("profile_id")
      try await grants.validate(context, scope: tool.scope, profileID: id)
      return try await profileTool(
        tool,
        input: input,
        context: context,
        profileID: id,
        timeZone: zone
      )
    } catch let failure as ReadQueryError {
      throw Self.accessFailure(failure)
    }
  }

  private func profileTool(
    _ tool: MCPToolDefinition,
    input: MCPToolArguments,
    context: MCPAuthorizationContext,
    profileID: UUID,
    timeZone: TimeZone
  ) async throws -> MCPToolResult {
    switch tool {
    case .profiles: throw MCPAccessFailure.invalidFilter
    case .status:
      let page = try await service.status(profileID: profileID, timeZone: timeZone)
      return try await encode(page: page, context: context)
    case .accounts, .categories, .earmarks:
      return try await list(
        tool,
        input: input,
        context: context,
        profileID: profileID,
        timeZone: timeZone
      )
    case .transactions:
      return try await transactions(
        input: input,
        context: context,
        profileID: profileID,
        timeZone: timeZone
      )
    case .transaction:
      let notes = try await includeNotes(input: input, context: context)
      let page = try await service.transaction(
        profileID: profileID,
        id: input.uuid("transaction_id"),
        includeNotes: notes,
        timeZone: timeZone
      )
      return try await encode(page: page, context: context)
    case .balances:
      return try await balances(
        input: input,
        context: context,
        profileID: profileID,
        timeZone: timeZone
      )
    case .summary:
      return try await summary(
        input: input,
        context: context,
        profileID: profileID,
        timeZone: timeZone
      )
    }
  }

  private func profiles(context: MCPAuthorizationContext, timeZone: TimeZone) async throws
    -> MCPToolResult
  {
    var items: [ReadProfileStatusDTO] = []
    for id in context.profileIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      try Task.checkCancellation()
      try await grants.validate(context, scope: .profiles, profileID: id)
      items.append(try await service.sessions.readProfileStatus(profileID: id))
    }
    return try await encode(
      MCPProfileListResult(
        queriedAt: now(),
        timeZone: timeZone.identifier,
        syncState: "unknown",
        items: items
      ),
      context: context
    )
  }

  func includeNotes(input: MCPToolArguments, context: MCPAuthorizationContext) async throws -> Bool
  {
    let requested = try input.bool("include_notes")
    if requested { try await grants.validate(context, scope: .transactionNotes) }
    return requested
  }

  static func accessFailure(_ error: ReadQueryError) -> MCPAccessFailure {
    switch error {
    case .invalidFilter: .invalidFilter
    case .notFound: .accessDenied
    case .profileUnavailable: .unavailable
    case .profileIncompatible: .incompatible
    case .cursorExpired: .cursorExpired
    case .resultTooLarge: .resultTooLarge
    case .priceUnavailable: .priceUnavailable
    }
  }
}

private struct MCPProfileListResult: Encodable, Sendable {
  let queriedAt: Date
  let timeZone: String
  let syncState: String
  let items: [ReadProfileStatusDTO]
}
