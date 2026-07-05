// Backends/GRDB/Records/WalletSyncCheckpointRow.swift

import Foundation
import GRDB

/// One row in the `wallet_sync_checkpoint` table — the highest confirmed
/// block number applied for a crypto-wallet / exchange account, synced
/// cross-device via CKSyncEngine (`WalletSyncCheckpointRecord`). This is a
/// SEPARATE record from the per-device `wallet_sync_state`: that one is
/// deliberately local-only, while this one is shared so a device that has
/// never synced can bootstrap from a peer's checkpoint.
///
/// `id` is `BLOB` matching `account.id` (UUID-as-BLOB in this project's
/// GRDB convention). `record_name` is the canonical CloudKit record name.
/// `needs_push` is the local-only dirty flag (never encoded on the wire);
/// `encoded_system_fields` caches the CKRecord change tag. Neither appears
/// in `CodingKeys`, so the synthesised persistence excludes them — the
/// repository writes them through explicit SQL like every other synced
/// table.
struct WalletSyncCheckpointRow {
  static let databaseTableName = "wallet_sync_checkpoint"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case lastSyncedBlockNumber = "last_synced_block_number"
    case encodedSystemFields = "encoded_system_fields"
    case needsPush = "needs_push"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case lastSyncedBlockNumber = "last_synced_block_number"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var lastSyncedBlockNumber: Int64
  var encodedSystemFields: Data?
}

extension WalletSyncCheckpointRow: Codable {}
extension WalletSyncCheckpointRow: Sendable {}
extension WalletSyncCheckpointRow: Identifiable {}
extension WalletSyncCheckpointRow: FetchableRecord {}
extension WalletSyncCheckpointRow: PersistableRecord {}
extension WalletSyncCheckpointRow: GRDBSystemFieldsStampable {}
