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
/// write side (`WalletApplyEngine.updateSyncState`) atomically raises the
/// checkpoint to `max(existing, head)` via `raiseToMax` so a device can never
/// lower the shared value, even when a peer's higher checkpoint lands via the
/// CloudKit apply path concurrently with this device's own write.
protocol WalletSyncCheckpointRepository: Sendable {
  /// Returns one account's synced checkpoint, or `nil` when no device has
  /// ever recorded one for the account.
  func load(accountId: UUID) async throws -> WalletSyncCheckpoint?

  /// Persists a checkpoint, upserting on `id`. Marks the row for push and
  /// fires the sync closure so the CKSyncEngine coordinator queues an
  /// upload — the same synced-mirror contract every other synced table uses.
  func save(_ checkpoint: WalletSyncCheckpoint) async throws

  /// Atomically raises this account's checkpoint to max(existing, blockNumber) in a single
  /// write transaction (serialized against the CloudKit apply writer by GRDB's writer queue),
  /// so a concurrently-applied higher peer value is never clobbered downward. Only marks the
  /// row for CloudKit push / fires the change hook when the stored value actually increases.
  func raiseToMax(accountId: UUID, blockNumber: UInt64) async throws
}
