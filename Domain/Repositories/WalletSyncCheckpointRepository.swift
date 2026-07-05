import Foundation

/// Cross-device sync checkpoint store for auto-imported accounts (on-chain
/// wallets and exchanges).
///
/// Unlike `WalletSyncStateRepository` — which is deliberately per-device and
/// local-only — implementations of this protocol persist a row that IS synced
/// via CKSyncEngine (`WalletSyncCheckpointRecord`). Every device therefore
/// shares the highest confirmed block number for an account, so a device that
/// has never fetched can bootstrap from a peer's checkpoint instead of a
/// genesis-style scan.
///
/// The read side (`WalletSyncEngine.build`) takes the higher of the local
/// `WalletSyncState` and this synced checkpoint when deriving `fromBlock`; the
/// write side (`WalletApplyEngine.updateSyncState`) max-merges before saving so
/// a device can never lower the shared value.
protocol WalletSyncCheckpointRepository: Sendable {
  /// Returns one account's synced checkpoint, or `nil` when no device has
  /// ever recorded one for the account.
  func load(accountId: UUID) async throws -> WalletSyncCheckpoint?

  /// Persists a checkpoint, upserting on `id`. Marks the row for push and
  /// fires the sync closure so the CKSyncEngine coordinator queues an
  /// upload — the same synced-mirror contract every other synced table uses.
  func save(_ checkpoint: WalletSyncCheckpoint) async throws
}
