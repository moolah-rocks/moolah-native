// Backends/GRDB/Repositories/GRDBEarmarkBudgetItemRepository.swift

import Foundation
import GRDB

/// Sync-only entry-point repo for `earmark_budget_item`. Read/write of
/// budget items goes through
/// `GRDBEarmarkRepository.fetchBudget(earmarkId:)` and
/// `GRDBEarmarkRepository.setBudget(earmarkId:categoryId:amount:)`;
/// this repo exists to satisfy the per-record-type sync dispatch tables
/// in `ProfileDataSyncHandler+GRDBDispatch` (and equivalents) so each
/// CloudKit `recordType` resolves to a typed `applyRemoteChangesSync`
/// entry point. There is no Domain protocol conformance.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBEarmarkBudgetItemRepository: @unchecked Sendable {
  private let database: any DatabaseWriter
  /// Defaulted to no-op closures — local mutations are emitted by
  /// `GRDBEarmarkRepository.setBudget` (it owns the read/write path).
  /// The hooks are kept on the type for symmetry with the other
  /// per-record-type repos and so a future caller that mutates this
  /// table directly does not have to retrofit the constructor.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(
    saved rows: [EarmarkBudgetItemRow], deleted ids: [UUID]
  ) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [EarmarkBudgetItemRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      _ = try EarmarkBudgetItemRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.id == id)
        .updateAll(
          database,
          [EarmarkBudgetItemRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Batch counterpart to `setEncodedSystemFieldsSync`. See
  /// `GRDBTransactionRepository.setEncodedSystemFieldsBatchSync` for
  /// the rationale (issue #865 follow-up).
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try EarmarkBudgetItemRow
          .filter(EarmarkBudgetItemRow.Columns.id == id)
          .updateAll(
            database,
            [EarmarkBudgetItemRow.Columns.encodedSystemFields.set(to: data)])
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
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.id == id)
        .updateAll(
          database, [EarmarkBudgetItemRow.Columns.encodedSystemFields.set(to: data)])
    }
    return updatedCount
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try EarmarkBudgetItemRow
      .filter(EarmarkBudgetItemRow.Columns.id == id)
      .updateAll(database, [EarmarkBudgetItemRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`. See
  /// `GRDBAccountRepository.dirtyIdsSync(from:in:)`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try EarmarkBudgetItemRow
      .filter(idSet.contains(EarmarkBudgetItemRow.Columns.id))
      .filter(EarmarkBudgetItemRow.Columns.needsPush == true)
      .select(EarmarkBudgetItemRow.Columns.id, as: UUID.self)
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
      try EarmarkBudgetItemRow
      .filter(Set(ids).contains(EarmarkBudgetItemRow.Columns.id))
      .updateAll(database, [EarmarkBudgetItemRow.Columns.needsPush.set(to: false)])
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try EarmarkBudgetItemRow
        .updateAll(
          database,
          [EarmarkBudgetItemRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.encodedSystemFields == nil)
        .select(EarmarkBudgetItemRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try EarmarkBudgetItemRow
        .select(EarmarkBudgetItemRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path
  /// in the sync handler.
  func fetchRowSync(id: UUID) throws -> EarmarkBudgetItemRow? {
    try database.read { database in
      try fetchRowSync(id: id, in: database)
    }
  }

  /// In-transaction counterpart to `fetchRowSync(id:)` (issue #1081).
  func fetchRowSync(id: UUID, in database: Database) throws -> EarmarkBudgetItemRow? {
    try EarmarkBudgetItemRow
      .filter(EarmarkBudgetItemRow.Columns.id == id)
      .fetchOne(database)
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [EarmarkBudgetItemRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try EarmarkBudgetItemRow
        .filter(idSet.contains(EarmarkBudgetItemRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try EarmarkBudgetItemRow.deleteAll(database)
    }
  }
}
