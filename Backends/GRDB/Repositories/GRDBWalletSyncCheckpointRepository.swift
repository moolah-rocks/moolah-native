import Foundation
import GRDB

/// GRDB-backed `WalletSyncCheckpointRepository`. One row per auto-imported
/// account in the synced `wallet_sync_checkpoint` table, carrying the highest
/// confirmed block number shared cross-device via CKSyncEngine
/// (`WalletSyncCheckpointRecord`).
///
/// This is a SYNCED mirror table, so `save(_:)` follows the same contract as
/// the closest sibling (`GRDBInsightDismissalRepository`): it upserts inside a
/// single writer transaction, marks the row `needs_push`, and fires
/// `onRecordChanged` so the coordinator queues a CloudKit upload. The
/// synchronous sync entry points the CKSyncEngine delegate needs
/// (`applyRemoteChangesSync`, `dirtyIdsSync`, `clearNeedsPushBatchSync`,
/// `setEncodedSystemFieldsBatchSync`, …) live on this concrete type; the
/// `+Sync` sibling carries the system-fields / needs-push helpers.
///
/// **`@unchecked Sendable` justification.** All stored properties are `let`.
/// `database` is `Sendable` (GRDB protocol guarantee — its serial executor
/// mediates concurrent access). `onRecordChanged` / `onRecordDeleted` are
/// `@Sendable` closures captured at init. Nothing mutates post-init. See
/// `guides/CONCURRENCY_GUIDE.md` §2 Carve-out 3 (GRDB repositories) — the
/// same waiver `GRDBInsightDismissalRepository` carries.
final class GRDBWalletSyncCheckpointRepository: WalletSyncCheckpointRepository, @unchecked Sendable
{
  let database: any DatabaseWriter
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

  func load(accountId: UUID) async throws -> WalletSyncCheckpoint? {
    try await database.read { database in
      try WalletSyncCheckpointRow
        .filter(WalletSyncCheckpointRow.Columns.id == accountId)
        .fetchOne(database)?
        .toDomain()
    }
  }

  func save(_ checkpoint: WalletSyncCheckpoint) async throws {
    // Read-modify-write inside ONE write block so the existing row's cached
    // `encoded_system_fields` (the CKRecord change tag) survives the upsert:
    // rebuilding the row from the domain value would reset it to nil and
    // trigger a spurious `.serverRecordChanged` on the next upload. Mirrors
    // `GRDBInsightDismissalRepository.recordDismissal`.
    let row = try await database.write { database -> WalletSyncCheckpointRow in
      var row =
        try WalletSyncCheckpointRow
        .filter(WalletSyncCheckpointRow.Columns.id == checkpoint.id)
        .fetchOne(database) ?? WalletSyncCheckpointRow(checkpoint: checkpoint)
      row.lastSyncedBlockNumber = Int64(checkpoint.lastSyncedBlockNumber)
      try row.upsert(database)
      try markNeedsPushSync(id: row.id, in: database)
      return row
    }
    onRecordChanged(WalletSyncCheckpointRow.recordType, row.id)
  }

  /// Atomically raises the checkpoint to `max(existing, blockNumber)` inside
  /// ONE write transaction, so a peer's higher value applied concurrently via
  /// `applyRemoteChangesSync` (the CKSyncEngine apply path, off `@MainActor`)
  /// can never be clobbered back down by this device's own read-then-save.
  /// GRDB's writer queue serializes this transaction against that apply
  /// writer, closing the TOCTOU window a separate `load` + `save` pair left
  /// open. Only marks the row `needs_push` / fires `onRecordChanged` when the
  /// stored value actually increases (or the row is new) — an unchanged
  /// checkpoint on an inactive account must not queue a redundant CloudKit
  /// upload every sync cycle.
  func raiseToMax(accountId: UUID, blockNumber: UInt64) async throws {
    let changedRowId: UUID? = try await database.write { database -> UUID? in
      let existingRow =
        try WalletSyncCheckpointRow
        .filter(WalletSyncCheckpointRow.Columns.id == accountId)
        .fetchOne(database)
      var row =
        existingRow
        ?? WalletSyncCheckpointRow(
          checkpoint: WalletSyncCheckpoint(id: accountId, lastSyncedBlockNumber: blockNumber))
      let newValue = Swift.max(row.lastSyncedBlockNumber, Int64(blockNumber))
      guard existingRow == nil || newValue > row.lastSyncedBlockNumber else { return nil }
      row.lastSyncedBlockNumber = newValue
      try row.upsert(database)
      try markNeedsPushSync(id: row.id, in: database)
      return row.id
    }
    if let changedRowId {
      onRecordChanged(WalletSyncCheckpointRow.recordType, changedRowId)
    }
  }

  /// Removes a checkpoint by account id and fires `onRecordDeleted` so the
  /// coordinator queues a CloudKit tombstone. Idempotent — a no-op when no
  /// row exists (absorbs the account-deletion / in-flight-sync race).
  func delete(accountId: UUID) async throws {
    let deleted = try await database.write { database in
      try WalletSyncCheckpointRow.deleteOne(database, id: accountId)
    }
    if deleted {
      onRecordDeleted(WalletSyncCheckpointRow.recordType, accountId)
    }
  }

  // Sync entry points are synchronous and block the GRDB queue. They are
  // called from the CKSyncEngine delegate executor off `@MainActor`. Never
  // call these from the main actor. See GRDBInsightDismissalRepository for
  // the shared rationale.

  func applyRemoteChangesSync(
    saved rows: [WalletSyncCheckpointRow], deleted ids: [UUID]
  ) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction apply. A plain upsert per incoming row: the max-merge that
  /// keeps a device from lowering the shared checkpoint is enforced on the
  /// WRITE side (`WalletApplyEngine.updateSyncState` saves
  /// `max(existing, head)`), so a synced value that reaches this apply path is
  /// already the max its origin device knew. A stale echo carrying a lower
  /// value is rejected upstream by the `needs_push` apply guard (a pending
  /// local edit is never overwritten) and the modification-date gate on the
  /// clean apply path — the same protection every other synced row relies on.
  func applyRemoteChangesSync(
    saved rows: [WalletSyncCheckpointRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids {
      _ = try WalletSyncCheckpointRow.deleteOne(database, id: id)
    }
  }

  func fetchRowSync(id: UUID) throws -> WalletSyncCheckpointRow? {
    try database.read { database in
      try fetchRowSync(id: id, in: database)
    }
  }

  /// In-transaction counterpart to `fetchRowSync(id:)`.
  func fetchRowSync(id: UUID, in database: Database) throws -> WalletSyncCheckpointRow? {
    try WalletSyncCheckpointRow
      .filter(WalletSyncCheckpointRow.Columns.id == id)
      .fetchOne(database)
  }

  func fetchRowsSync(ids: [UUID]) throws -> [WalletSyncCheckpointRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try WalletSyncCheckpointRow
        .filter(idSet.contains(WalletSyncCheckpointRow.Columns.id))
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try WalletSyncCheckpointRow
        .select(WalletSyncCheckpointRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try WalletSyncCheckpointRow
        .filter(WalletSyncCheckpointRow.Columns.encodedSystemFields == nil)
        .select(WalletSyncCheckpointRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try WalletSyncCheckpointRow.deleteAll(database)
    }
  }
}
