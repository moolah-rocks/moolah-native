import Foundation
import MoolahMCP

/// One bounded transaction per call, always off the UI/HTTP caller's executor.
/// The history actor serializes these transactions; no profile database is opened.
struct MCPAuditFile: Sendable {
  enum Action: Sendable {
    case read
    case append(MCPAuditEvent)
    case clear
  }

  let url: URL
  let now: @Sendable () -> Date
  private let maximumBytes = 524288

  @concurrent
  func apply(_ action: Action) async throws -> [MCPAuditEvent] {
    try Task.checkCancellation()
    if case .clear = action {
      try save([])
      return []
    }
    let original = try load()
    var retained = prune(original)
    switch action {
    case .read:
      if retained.count != original.count { try save(retained) }
    case .append(let event):
      try validate(event)
      retained = prune(retained + [event])
      try Task.checkCancellation()
      try save(retained)
    case .clear: break
    }
    return retained
  }

  private func validate(_ event: MCPAuditEvent) throws {
    let tools: Set<String> = [
      "moolah_list_profiles", "moolah_get_status", "moolah_list_accounts",
      "moolah_get_balances", "moolah_find_transactions", "moolah_get_transaction",
      "moolah_list_categories", "moolah_list_earmarks", "moolah_get_summary", "unknown",
    ]
    let outcomes = Set(MCPAccessFailure.allAuditCodes).union(["OK", "TOOL_ERROR"])
    guard tools.contains(event.tool), outcomes.contains(event.outcome),
      event.duration.isFinite, event.duration >= 0
    else { throw MCPStorageFailure.invalidData }
  }

  private func prune(_ events: [MCPAuditEvent]) -> [MCPAuditEvent] {
    let instant = now()
    let cutoff = instant.addingTimeInterval(-7 * 86400)
    return Array(events.filter { $0.timestamp > cutoff && $0.timestamp <= instant }.suffix(1000))
  }

  private func load() throws -> [MCPAuditEvent] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes + 1
    guard size <= maximumBytes else { throw MCPStorageFailure.invalidData }
    let data = try Data(contentsOf: url)
    let events = try JSONDecoder().decode([MCPAuditEvent].self, from: data)
    guard events.count <= 1000 else { throw MCPStorageFailure.invalidData }
    for event in events { try validate(event) }
    return events
  }

  private func save(_ events: [MCPAuditEvent]) throws {
    let data = try JSONEncoder().encode(events)
    guard data.count <= maximumBytes else { throw MCPStorageFailure.invalidData }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

extension MCPAccessFailure {
  static let allAuditCodes = [
    accessDenied, invalidFilter, cursorExpired, queryLimit, rateLimited, queryTimeout,
    queryCancelled, resultTooLarge, calculationLimit, responseTooLarge, unavailable, incompatible,
    priceUnavailable, unsupported,
    internalFailure,
  ].map(\.rawValue)
}
