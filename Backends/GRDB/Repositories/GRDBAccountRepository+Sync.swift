// Backends/GRDB/Repositories/GRDBAccountRepository+Sync.swift

import Foundation
import GRDB

// MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
//
// Called from the CKSyncEngine delegate executor on a non-MainActor
// context. `DatabaseWriter.write { db in … }` has both async and sync
// overloads; the sync form blocks the calling thread until the queue's
// serial executor admits the closure. Never call these from
// `@MainActor`. Mirrors `GRDBTransactionRepository+Sync.swift`.

extension GRDBAccountRepository {
  func applyRemoteChangesSync(saved rows: [AccountRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [AccountRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      // Replicates the v3-era ON DELETE CASCADE on
      // `investment_value.account_id` and ON DELETE SET NULL on
      // `transaction_leg.account_id` after `v5_drop_foreign_keys`
      // removed the FKs. Same write transaction so the cascade is
      // atomic with the parent delete.
      _ =
        try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.accountId == id)
        .deleteAll(database)
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.accountId == id)
        .updateAll(
          database,
          [TransactionLegRow.Columns.accountId.set(to: nil)])
      _ = try AccountRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try AccountRow
        .filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.encodedSystemFields.set(to: data)])
        > 0
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
          try AccountRow
          .filter(AccountRow.Columns.id == id)
          .updateAll(
            database,
            [AccountRow.Columns.encodedSystemFields.set(to: data)])
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
        try AccountRow
        .filter(AccountRow.Columns.id == id)
        .updateAll(database, [AccountRow.Columns.encodedSystemFields.set(to: data)])
    }
    return updatedCount
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// Called from every mutation so the apply path (issue #1081) can detect
  /// an in-flight local edit transactionally.
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try AccountRow
      .filter(AccountRow.Columns.id == id)
      .updateAll(database, [AccountRow.Columns.needsPush.set(to: true)])
  }

  /// Returns the subset of `ids` whose row currently has `needs_push = 1`.
  /// Read inside the apply write transaction (pass that `database`); the
  /// overload without `database` opens its own read for non-apply callers.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try AccountRow
      .filter(idSet.contains(AccountRow.Columns.id))
      .filter(AccountRow.Columns.needsPush == true)
      .select(AccountRow.Columns.id, as: UUID.self)
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

  /// In-transaction counterpart to `clearNeedsPushBatchSync(_:)`. Runs
  /// against the caller's active `database` (no nested write) so the
  /// upload-ack path can re-read the current row, compare it to the sent
  /// record, and clear the flag all inside one transaction — leaving no
  /// window for a concurrent edit to interleave between compare and clear
  /// (issue #1081).
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID], in database: Database) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return
      try AccountRow
      .filter(Set(ids).contains(AccountRow.Columns.id))
      .updateAll(database, [AccountRow.Columns.needsPush.set(to: false)])
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try AccountRow
        .updateAll(
          database,
          [AccountRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try AccountRow
        .filter(AccountRow.Columns.encodedSystemFields == nil)
        .select(AccountRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try AccountRow
        .select(AccountRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> AccountRow? {
    try database.read { database in
      try fetchRowSync(id: id, in: database)
    }
  }

  /// In-transaction counterpart to `fetchRowSync(id:)`. Reads against the
  /// caller's active `database` so the upload-ack path's compare-and-clear
  /// shares one transaction (issue #1081).
  func fetchRowSync(id: UUID, in database: Database) throws -> AccountRow? {
    try AccountRow
      .filter(AccountRow.Columns.id == id)
      .fetchOne(database)
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [AccountRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try AccountRow
        .filter(idSet.contains(AccountRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try AccountRow.deleteAll(database)
    }
  }
}
