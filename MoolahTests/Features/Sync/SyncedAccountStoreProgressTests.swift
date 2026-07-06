// MoolahTests/Features/Sync/SyncedAccountStoreProgressTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SyncedAccountStore.progressPerAccount` / `setSyncProgress`.
/// This is the observable seam the windowed wallet-sync runner writes to
/// and the sync-button view reads from — it carries no sync-algorithm
/// behaviour itself, just the store-side plumbing and the
/// `WalletSyncProgress.scanning(fraction:)` clamp.
@Suite("SyncedAccountStore — sync progress")
@MainActor
struct SyncedAccountStoreProgressTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeStore() throws -> SyncedAccountStore {
    let (backend, _) = try TestBackend.create()
    let checkpoints = InMemoryWalletSyncCheckpointRepository()
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      checkpoints: checkpoints,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    return SyncedAccountStore(
      sources: [],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      walletSyncCheckpoints: checkpoints,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow })
  }

  @Test("progressPerAccount starts empty")
  func startsEmpty() throws {
    let store = try makeStore()

    #expect(store.progressPerAccount.isEmpty)
  }

  @Test("setSyncProgress records progress for the account")
  func setsProgress() throws {
    let store = try makeStore()
    let accountId = UUID()

    store.setSyncProgress(.scanning(fraction: 0.5), for: accountId)

    #expect(store.progressPerAccount[accountId] == .scanning(fraction: 0.5))
  }

  @Test("scanning fraction above 1 is clamped to 1")
  func clampsFractionAboveOne() throws {
    let store = try makeStore()
    let accountId = UUID()

    store.setSyncProgress(.scanning(fraction: 2.0), for: accountId)

    #expect(store.progressPerAccount[accountId] == .scanning(fraction: 1.0))
  }

  @Test("scanning fraction below 0 is clamped to 0")
  func clampsFractionBelowZero() throws {
    let store = try makeStore()
    let accountId = UUID()

    store.setSyncProgress(.scanning(fraction: -1.0), for: accountId)

    #expect(store.progressPerAccount[accountId] == .scanning(fraction: 0.0))
  }

  @Test("setSyncProgress(nil, …) removes the entry")
  func clearsProgress() throws {
    let store = try makeStore()
    let accountId = UUID()
    store.setSyncProgress(.scanning(fraction: 0.5), for: accountId)

    store.setSyncProgress(nil, for: accountId)

    #expect(store.progressPerAccount[accountId] == nil)
  }
}
