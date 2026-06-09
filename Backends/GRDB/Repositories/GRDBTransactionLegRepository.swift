// Backends/GRDB/Repositories/GRDBTransactionLegRepository.swift

import Foundation
import GRDB

/// Sync-only entry-point repo for `transaction_leg`. Read/write of legs
/// is orchestrated by `GRDBTransactionRepository` (header + legs in one
/// transaction); this repo exists to satisfy the per-record-type sync
/// dispatch tables in `ProfileDataSyncHandler+GRDBDispatch` (and
/// equivalents) so each CloudKit `recordType` resolves to a typed
/// `applyRemoteChangesSync` entry point. There is no Domain protocol
/// conformance.
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
final class GRDBTransactionLegRepository: @unchecked Sendable {
  private let database: any DatabaseWriter
  /// Defaulted to no-op closures — local mutations on legs are emitted
  /// by `GRDBTransactionRepository.create / update / delete` (which own
  /// the header + legs write transaction). The hooks are kept on the
  /// type for symmetry with the other per-record-type repos.
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
    saved rows: [TransactionLegRow], deleted ids: [UUID]
  ) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [TransactionLegRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      _ = try TransactionLegRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == id)
        .updateAll(
          database,
          [TransactionLegRow.Columns.encodedSystemFields.set(to: data)])
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
          try TransactionLegRow
          .filter(TransactionLegRow.Columns.id == id)
          .updateAll(
            database,
            [TransactionLegRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.id == id)
      .updateAll(database, [TransactionLegRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`. See
  /// `GRDBAccountRepository.dirtyIdsSync(from:in:)`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try TransactionLegRow
      .filter(idSet.contains(TransactionLegRow.Columns.id))
      .filter(TransactionLegRow.Columns.needsPush == true)
      .select(TransactionLegRow.Columns.id, as: UUID.self)
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
      try TransactionLegRow
        .filter(Set(ids).contains(TransactionLegRow.Columns.id))
        .updateAll(database, [TransactionLegRow.Columns.needsPush.set(to: false)])
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try TransactionLegRow
        .updateAll(
          database,
          [TransactionLegRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.encodedSystemFields == nil)
        .select(TransactionLegRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try TransactionLegRow
        .select(TransactionLegRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path
  /// in the sync handler.
  func fetchRowSync(id: UUID) throws -> TransactionLegRow? {
    try database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [TransactionLegRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try TransactionLegRow
        .filter(idSet.contains(TransactionLegRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try TransactionLegRow.deleteAll(database)
    }
  }
}
