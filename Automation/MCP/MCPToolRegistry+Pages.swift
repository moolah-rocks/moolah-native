import Foundation
import MoolahMCP

/// Canonical validated query meaning, independent of caller key order or UUID/set spelling.
struct MCPPageFilters: Codable, Sendable {
  let limit: Int
  let timeZone: String
  var includeHidden = false
  var fromDate: String?
  var toDate: String?
  var accountIDs: [UUID] = []
  var categoryIDs: [UUID] = []
  var payeeQuery: String?
  var scheduled = false
  var includeNotes = false
  var reportingInstrument: String?
  var balanceMode = "positions"
}

extension MCPToolRegistry {
  func list(
    _ tool: MCPToolDefinition,
    input: MCPToolArguments,
    context: MCPAuthorizationContext,
    profileID: UUID,
    timeZone: TimeZone
  ) async throws -> MCPToolResult {
    var filters = MCPPageFilters(limit: try input.limit(), timeZone: timeZone.identifier)
    if tool == .accounts { filters.includeHidden = try input.bool("include_hidden") }
    let binding = try cursorBinding(
      tool: tool,
      profileID: profileID,
      context: context,
      filters: filters
    )
    let request = try pageRequest(input: input, binding: binding, limit: filters.limit)
    switch tool {
    case .accounts:
      let page = try await service.accounts(
        profileID: profileID,
        includeHidden: filters.includeHidden,
        page: request,
        timeZone: timeZone
      )
      return try await encode(page: page, context: context, binding: binding)
    case .categories:
      let page = try await service.categories(
        profileID: profileID,
        page: request,
        timeZone: timeZone
      )
      return try await encode(page: page, context: context, binding: binding)
    case .earmarks:
      let page = try await service.earmarks(profileID: profileID, page: request, timeZone: timeZone)
      return try await encode(page: page, context: context, binding: binding)
    default: throw MCPAccessFailure.invalidFilter
    }
  }

  func transactions(
    input: MCPToolArguments,
    context: MCPAuthorizationContext,
    profileID: UUID,
    timeZone: TimeZone
  ) async throws -> MCPToolResult {
    let range = try input.dateRange(timeZone: timeZone, horizon: .transactions)
    let accountIDs = try input.ids("account_ids")
    let categoryIDs = try input.ids("category_ids")
    let query = try input.string("payee_query")
    let scheduled = try input.bool("scheduled")
    let notes = try await includeNotes(input: input, context: context)
    var filters = MCPPageFilters(limit: try input.limit(), timeZone: timeZone.identifier)
    filters.fromDate = try input.string("from_date")
    filters.toDate = try input.string("to_date")
    filters.accountIDs = accountIDs.sorted { $0.uuidString < $1.uuidString }
    filters.categoryIDs = categoryIDs.sorted { $0.uuidString < $1.uuidString }
    filters.payeeQuery = query
    filters.scheduled = scheduled
    filters.includeNotes = notes
    let binding = try cursorBinding(
      tool: .transactions,
      profileID: profileID,
      context: context,
      filters: filters
    )
    let search = try ReadTransactionSearch(
      range: range,
      accountIDs: accountIDs,
      categoryIDs: categoryIDs,
      payeeQuery: query,
      scheduled: scheduled
    )
    let page = try await service.transactions(
      profileID: profileID,
      search: search,
      page: pageRequest(input: input, binding: binding, limit: filters.limit),
      includeNotes: notes
    )
    return try await encode(page: page, context: context, binding: binding)
  }

  func cursorBinding(
    tool: MCPToolDefinition,
    profileID: UUID,
    context: MCPAuthorizationContext,
    filters: MCPPageFilters
  ) throws -> MCPCursorBinding {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try MCPCursorBinding(
      context: context,
      profileID: profileID,
      tool: tool.rawValue,
      canonicalFilters: encoder.encode(filters)
    )
  }

  func pageRequest(
    input: MCPToolArguments,
    binding: MCPCursorBinding,
    limit: Int
  ) throws -> ReadPageRequest {
    guard let cursor = try input.string("cursor", maximumBytes: 8192) else {
      return try ReadPageRequest(limit: limit)
    }
    let continuation = try cursors.decode(cursor, binding: binding)
    // Internal Date coding preserves subsecond keyset precision; this is not a wire date.
    guard let key = try? JSONDecoder().decode(ReadPageKey.self, from: continuation.key) else {
      throw MCPAccessFailure.cursorExpired
    }
    return try ReadPageRequest(limit: limit, after: key, revision: continuation.revision)
  }
}
