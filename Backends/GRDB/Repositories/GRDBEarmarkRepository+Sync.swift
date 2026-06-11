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
      try clearNeedsPushBatchSync(ids, in: database)
    }
  }

  /// In-transaction counterpart to `clearNeedsPushBatchSync(_:)` — see
  /// `GRDBAccountRepository` for the atomic compare-and-clear rationale
  /// (issue #1081).
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID], in database: Database) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return
      try EarmarkRow
      .filter(Set(ids).contains(EarmarkRow.Columns.id))
      .updateAll(database, [EarmarkRow.Columns.needsPush.set(to: false)])
  }

  func applyRemoteChangesSync(saved rows: [EarmarkRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  ///
  /// Earmark rows carry no app-originated deletion (earmarks are soft-hidden
  /// via `update`, never hard-deleted), so there is no deletion intent to
  /// clear on a peer save. The apply-path budget-item / earmark deletes below
  /// are server-originated and never journaled.
  func applyRemoteChangesSync(
    saved rows: [EarmarkRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids {
      // Replaces v3's ON DELETE CASCADE on earmark_budget_item.earmark_id
      // and ON DELETE SET NULL on transaction_leg.earmark_id (both
      // dropped in v5_drop_foreign_keys).
      _ =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.earmarkId == id)
        .deleteAll(database)
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.earmarkId == id)
        .updateAll(
          database,
          [TransactionLegRow.Columns.earmarkId.set(to: nil)])
      _ = try EarmarkRow.deleteOne(database, id: id)
    }
  }
}
