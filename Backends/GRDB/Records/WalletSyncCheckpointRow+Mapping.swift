// Backends/GRDB/Records/WalletSyncCheckpointRow+Mapping.swift

import Foundation

extension WalletSyncCheckpointRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "WalletSyncCheckpointRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed row.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `WalletSyncCheckpoint`. Derives the record
  /// name from the id; `encodedSystemFields` starts nil (stamped post-upsert).
  /// The `UInt64`→`Int64` narrowing mirrors `WalletSyncStateRow+Mapping`:
  /// block numbers are far below `Int64.max`, so the conversion is lossless.
  init(checkpoint: WalletSyncCheckpoint) {
    self.id = checkpoint.id
    self.recordName = Self.recordName(for: checkpoint.id)
    self.lastSyncedBlockNumber = Int64(checkpoint.lastSyncedBlockNumber)
    self.encodedSystemFields = nil
  }

  /// Reconstructs the domain `WalletSyncCheckpoint`. A negative stored value
  /// (only reachable via corruption) clamps to `0` before the `Int64`→`UInt64`
  /// widening, matching `WalletSyncStateRow+Mapping`.
  func toDomain() -> WalletSyncCheckpoint {
    WalletSyncCheckpoint(
      id: id,
      lastSyncedBlockNumber: UInt64(max(0, lastSyncedBlockNumber)))
  }
}
