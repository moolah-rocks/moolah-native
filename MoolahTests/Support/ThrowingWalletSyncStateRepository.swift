import Foundation

@testable import Moolah

/// Thrown by the throwing/selective `WalletSyncState`/`WalletSyncCheckpoint`
/// test doubles below.
struct StubWriteFailure: Error {}

/// `WalletSyncStateRepository` double whose `save` always throws — used to
/// prove `WalletApplyEngine.updateSyncState` is best-effort per account: a
/// watermark-write failure must not propagate out of `apply()`, since
/// `persist(_:)` has already committed the cycle's transactions by the time
/// `updateSyncState` runs.
actor ThrowingWalletSyncStateRepository: WalletSyncStateRepository {
  func loadAll() async throws -> [WalletSyncState] { [] }
  func load(accountId: UUID) async throws -> WalletSyncState? { nil }
  func save(_ state: WalletSyncState) async throws { throw StubWriteFailure() }
  func delete(accountId: UUID) async throws {}
}

/// `WalletSyncCheckpointRepository` double whose `raiseToMax` always
/// throws — the checkpoint-side counterpart to
/// `ThrowingWalletSyncStateRepository`, above.
actor ThrowingWalletSyncCheckpointRepository: WalletSyncCheckpointRepository {
  func load(accountId: UUID) async throws -> WalletSyncCheckpoint? { nil }
  func save(_ checkpoint: WalletSyncCheckpoint) async throws {}
  func raiseToMax(accountId: UUID, blockNumber: UInt64) async throws {
    throw StubWriteFailure()
  }
  func delete(accountId: UUID) async throws {}
}

/// `WalletSyncStateRepository` double that throws `save` only for accounts
/// named via `failSaves(for:)`, and records every successful save — proves
/// one account's per-account failure doesn't block another account's write
/// in the same `updateSyncState` loop.
actor SelectiveWalletSyncStateRepository: WalletSyncStateRepository {
  private var failingAccountIds: Set<UUID> = []
  private var saved: [UUID: WalletSyncState] = [:]

  func failSaves(for accountId: UUID) {
    failingAccountIds.insert(accountId)
  }

  func savedState(for accountId: UUID) -> WalletSyncState? {
    saved[accountId]
  }

  func loadAll() async throws -> [WalletSyncState] { Array(saved.values) }
  func load(accountId: UUID) async throws -> WalletSyncState? { saved[accountId] }

  func save(_ state: WalletSyncState) async throws {
    guard !failingAccountIds.contains(state.id) else { throw StubWriteFailure() }
    saved[state.id] = state
  }

  func delete(accountId: UUID) async throws { saved[accountId] = nil }
}
