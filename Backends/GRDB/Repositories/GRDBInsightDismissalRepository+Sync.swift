import Foundation
import GRDB

extension GRDBInsightDismissalRepository {
  /// Batch counterpart to `setEncodedSystemFieldsSync` — writes every update
  /// in a single transaction so `databaseDidCommit` fires once. See
  /// `GRDBAccountGroupRepository+Sync` and issue #865.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try InsightDismissalRow
          .filter(InsightDismissalRow.Columns.id == id)
          .updateAll(
            database,
            [InsightDismissalRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try InsightDismissalRow
      .filter(InsightDismissalRow.Columns.id == id)
      .updateAll(database, [InsightDismissalRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`. See
  /// `GRDBAccountRepository.dirtyIdsSync(from:in:)`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try InsightDismissalRow
      .filter(idSet.contains(InsightDismissalRow.Columns.id))
      .filter(InsightDismissalRow.Columns.needsPush == true)
      .select(InsightDismissalRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    return Set(rows)
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { database in try dirtyIdsSync(from: ids, in: database) }
  }

  /// Clears `needs_push` for the given ids in one transaction. Returns the
  /// number of rows updated.
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { database in
      try InsightDismissalRow
        .filter(Set(ids).contains(InsightDismissalRow.Columns.id))
        .updateAll(database, [InsightDismissalRow.Columns.needsPush.set(to: false)])
    }
  }
}
