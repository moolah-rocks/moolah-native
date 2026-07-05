import Foundation
import GRDB

extension GRDBWalletSyncCheckpointRepository {
  /// Batch counterpart to a single system-fields write — writes every update
  /// in one transaction so `databaseDidCommit` fires once. Mirrors
  /// `GRDBInsightDismissalRepository+Sync`.
  @discardableResult
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      try setEncodedSystemFieldsBatchSync(updates, in: database)
    }
  }

  /// In-transaction counterpart to `setEncodedSystemFieldsBatchSync(_:)`.
  /// Writes against the caller's active `database` (no nested write) so a
  /// dirty echo's system-fields-only update shares the apply transaction
  /// that read `needs_push`.
  @discardableResult
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)], in database: Database
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    var updatedCount = 0
    for (id, data) in updates {
      updatedCount +=
        try WalletSyncCheckpointRow
        .filter(WalletSyncCheckpointRow.Columns.id == id)
        .updateAll(
          database, [WalletSyncCheckpointRow.Columns.encodedSystemFields.set(to: data)])
    }
    return updatedCount
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try WalletSyncCheckpointRow
        .updateAll(
          database,
          [WalletSyncCheckpointRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try WalletSyncCheckpointRow
      .filter(WalletSyncCheckpointRow.Columns.id == id)
      .updateAll(database, [WalletSyncCheckpointRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try WalletSyncCheckpointRow
      .filter(idSet.contains(WalletSyncCheckpointRow.Columns.id))
      .filter(WalletSyncCheckpointRow.Columns.needsPush == true)
      .select(WalletSyncCheckpointRow.Columns.id, as: UUID.self)
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

  /// In-transaction counterpart to `clearNeedsPushBatchSync(_:)`.
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID], in database: Database) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return
      try WalletSyncCheckpointRow
      .filter(Set(ids).contains(WalletSyncCheckpointRow.Columns.id))
      .updateAll(database, [WalletSyncCheckpointRow.Columns.needsPush.set(to: false)])
  }
}
