// Backends/GRDB/Repositories/GRDBEarmarkRepository+Sync.swift

import Foundation
import GRDB

extension GRDBEarmarkRepository {
  /// Static `needs_push = 1` mark for a budget-item row (cross-table
  /// relative to this repo's own `earmark` table), callable from the
  /// `static` `setBudget` pipeline helper (issue #1081).
  static func markBudgetItemNeedsPush(id: UUID, in database: Database) throws {
    _ =
      try EarmarkBudgetItemRow
      .filter(EarmarkBudgetItemRow.Columns.id == id)
      .updateAll(database, [EarmarkBudgetItemRow.Columns.needsPush.set(to: true)])
  }

  /// Batch counterpart to `setEncodedSystemFieldsSync` — writes every
  /// update in a single GRDB transaction so `databaseDidCommit` fires
  /// once rather than once per row. See the doc on
  /// `GRDBTransactionRepository.setEncodedSystemFieldsBatchSync` for
  /// the rationale and issue #865 for the follow-up that drops the
  /// observation-region dependency on this column.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try EarmarkRow
          .filter(EarmarkRow.Columns.id == id)
          .updateAll(
            database,
            [EarmarkRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// In-transaction counterpart to `setEncodedSystemFieldsBatchSync(_:)`.
  /// Writes against the caller's active `database` (no nested write) so a
  /// dirty echo's system-fields-only update shares the apply transaction
  /// that read `needs_push` (issue #1081).
  @discardableResult
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)], in database: Database
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    var updatedCount = 0
    for (id, data) in updates {
      updatedCount +=
        try EarmarkRow
        .filter(EarmarkRow.Columns.id == id)
        .updateAll(database, [EarmarkRow.Columns.encodedSystemFields.set(to: data)])
    }
    return updatedCount
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try EarmarkRow
      .filter(EarmarkRow.Columns.id == id)
      .updateAll(database, [EarmarkRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`. See
  /// `GRDBAccountRepository.dirtyIdsSync(from:in:)`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try EarmarkRow
      .filter(idSet.contains(EarmarkRow.Columns.id))
      .filter(EarmarkRow.Columns.needsPush == true)
      .select(EarmarkRow.Columns.id, as: UUID.self)
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
      try EarmarkRow
        .filter(Set(ids).contains(EarmarkRow.Columns.id))
        .updateAll(database, [EarmarkRow.Columns.needsPush.set(to: false)])
    }
  }
}
