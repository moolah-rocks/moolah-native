import Foundation

/// Cross-device sync checkpoint for an auto-imported account (on-chain
/// wallet or exchange). Unlike `WalletSyncState` — which is deliberately
/// per-device and local-only — this record IS synced via CKSyncEngine so
/// every device shares the highest confirmed block number for the account.
/// A device that has never fetched can start from a peer's checkpoint
/// instead of a genesis-style scan.
///
/// `id` doubles as the account UUID for `Identifiable` consumers.
struct WalletSyncCheckpoint: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  /// Highest confirmed block applied for the account, shared cross-device.
  var lastSyncedBlockNumber: UInt64
}
