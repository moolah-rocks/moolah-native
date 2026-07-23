import Foundation
import GRDB

/// GRDB-backed local display history. Rows expire after 90 days: the ranking
/// penalty has decayed to effectively zero by then, while pruning event keys
/// prevents transaction-specific history from growing forever.
struct GRDBInsightDisplayHistoryRepository: InsightDisplayHistoryRepository, Sendable {
  private static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60

  private let database: any DatabaseWriter

  init(database: any DatabaseWriter) {
    self.database = database
  }

  func fetchLastShown() async throws -> [String: Date] {
    try await database.read { database in
      let rows = try InsightDisplayHistoryRow.fetchAll(database)
      return Dictionary(uniqueKeysWithValues: rows.map { ($0.presentationKey, $0.lastShownAt) })
    }
  }

  func recordShown(_ presentationKeys: Set<String>, at date: Date) async throws {
    guard !presentationKeys.isEmpty else { return }
    try await database.write { database in
      for key in presentationKeys {
        let existing = try InsightDisplayHistoryRow.fetchOne(database, key: key)
        let lastShownAt = existing?.lastShownAt ?? .distantPast
        guard lastShownAt < date else { continue }
        try InsightDisplayHistoryRow(presentationKey: key, lastShownAt: date).save(database)
      }
      let cutoff = date.addingTimeInterval(-Self.retentionInterval)
      _ =
        try InsightDisplayHistoryRow
        .filter(InsightDisplayHistoryRow.Columns.lastShownAt < cutoff)
        .deleteAll(database)
    }
  }
}
