// Backends/GRDB/Repositories/GRDBCategoryRepository+Sync.swift

import Foundation
import GRDB

extension GRDBCategoryRepository {
  /// Marks every row whose *field values* were changed by a category
  /// delete (children re-parented, legs re-categorised, budgets
  /// re-pointed) `needs_push = 1`, inside the caller's delete transaction,
  /// so the apply path (issue #1081) can't clobber the local edit. The
  /// deleted category and any deleted budget items are removals — out of
  /// `needs_push` scope, which guards saves only.
  static func markDeleteSideEffectsNeedsPush(
    orphanedChildIds: [UUID],
    reassignedLegIds: [UUID],
    updatedBudgetIds: [UUID],
    in database: Database
  ) throws {
    for childId in orphanedChildIds {
      _ =
        try CategoryRow
        .filter(CategoryRow.Columns.id == childId)
        .updateAll(database, [CategoryRow.Columns.needsPush.set(to: true)])
    }
    for legId in reassignedLegIds {
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == legId)
        .updateAll(database, [TransactionLegRow.Columns.needsPush.set(to: true)])
    }
    for budgetId in updatedBudgetIds {
      _ =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.id == budgetId)
        .updateAll(database, [EarmarkBudgetItemRow.Columns.needsPush.set(to: true)])
    }
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
          try CategoryRow
          .filter(CategoryRow.Columns.id == id)
          .updateAll(
            database,
            [CategoryRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try CategoryRow
      .filter(CategoryRow.Columns.id == id)
      .updateAll(database, [CategoryRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`. See
  /// `GRDBAccountRepository.dirtyIdsSync(from:in:)`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try CategoryRow
      .filter(idSet.contains(CategoryRow.Columns.id))
      .filter(CategoryRow.Columns.needsPush == true)
      .select(CategoryRow.Columns.id, as: UUID.self)
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
      try CategoryRow
        .filter(Set(ids).contains(CategoryRow.Columns.id))
        .updateAll(database, [CategoryRow.Columns.needsPush.set(to: false)])
    }
  }
}
