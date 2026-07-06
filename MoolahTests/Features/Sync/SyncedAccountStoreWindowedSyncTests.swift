// MoolahTests/Features/Sync/SyncedAccountStoreWindowedSyncTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `SyncedAccountStore`'s windowed-sync routing — the
/// seam that sends direct-RPC crypto accounts through the resumable,
/// determinate `WindowedWalletSyncRunner` while the Alchemy path
/// (`didWindowedScan == false`) and every non-crypto source keep today's
/// single-shot build → apply batch. The shared harness lives in
/// `WindowedSyncStore.swift`; the windowed↔single-shot union pass has its own
/// suite in `SyncedAccountStoreWindowedUnionTests.swift`.
@Suite("SyncedAccountStore — windowed direct-RPC routing")
@MainActor
struct SyncedAccountStoreWindowedSyncTests {
  private typealias Store = WindowedSyncStore

  // MARK: - Direct path advances the checkpoint to head

  @Test("A direct-path crypto account walks its windows and ends at head")
  func directPathAdvancesCheckpointToHead() async throws {
    let fixture = try Store.makeFixture(head: 600_000)
    let account = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    try await fixture.seedFreshState(for: [account])
    await fixture.store.loadInitialState()

    await fixture.store.syncAccounts([account])

    // Windows [0, 249_999], [250_000, 499_999], [500_000, 600_000] each
    // scanned via the runner, not the single-shot Alchemy path.
    #expect(fixture.chain.recordedFromBlocks == [0, 250_000, 500_000])
    let checkpoint = try await fixture.backend.walletSyncCheckpoints.load(
      accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 600_000)
    let state = try await fixture.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 600_000)
    #expect(state?.lastSyncedAt == Store.pinnedNow)
    // Progress cleared once the cycle completes.
    #expect(fixture.store.progressPerAccount[account.id] == nil)
  }

  // MARK: - Determinate progress: scanning mid-scan, cleared after

  @Test("progressPerAccount is .scanning mid-scan and nil after the cycle")
  func progressIsScanningMidScanThenCleared() async throws {
    let fixture = try Store.makeFixture(head: 600_000)
    let account = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    try await fixture.seedFreshState(for: [account])
    await fixture.store.loadInitialState()

    // Snapshot the store's published progress from inside a window fetch —
    // a genuine mid-scan suspension point.
    let snapshots = ProgressSnapshots()
    let store = fixture.store
    let accountId = account.id
    fixture.chain.setOnGetAssetTransfers {
      snapshots.append(store.progressPerAccount[accountId])
    }

    await fixture.store.syncAccounts([account])

    let scanning = snapshots.all.compactMap { $0 }.filter {
      if case .scanning = $0 { return true }
      return false
    }
    #expect(!scanning.isEmpty, "expected a .scanning snapshot while a window was in flight")
    #expect(fixture.store.progressPerAccount[account.id] == nil)
  }

  // MARK: - Alchemy path falls back to the single-shot batch

  @Test("A nil-head account syncs via single-shot with no scanning progress")
  func alchemyPathSyncsViaSingleShotWithoutScanningProgress() async throws {
    // head == nil → the runner reports didWindowedScan == false → fallback.
    let fixture = try Store.makeFixture(head: nil)
    let account = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    try await fixture.seedFreshState(for: [account])
    fixture.chain.setRowsForAnyCall([
      Store.inboundERC20(
        hash: "0xalchemy", to: Store.walletA, contractAddress: "0xtoken", blockNum: 100)
    ])
    await fixture.store.loadInitialState()

    // Capture progress at the single-shot fetch's suspension point; the
    // single-shot path must never publish determinate progress.
    let snapshots = ProgressSnapshots()
    let store = fixture.store
    let accountId = account.id
    fixture.chain.setOnGetAssetTransfers {
      snapshots.append(store.progressPerAccount[accountId])
    }

    await fixture.store.syncAccounts([account])

    // The single-shot build+apply still persisted the transfer.
    let txns = try await fixture.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(txns.count == 1)
    // No determinate progress was ever published, and none lingers.
    let sawScanning = snapshots.all.contains {
      if case .scanning = $0 { return true }
      return false
    }
    #expect(sawScanning == false)
    #expect(fixture.store.progressPerAccount[account.id] == nil)
  }

  // MARK: - A mid-run window failure records the error but stays retryable

  @Test("A failed later window records lastError, keeps the checkpoint, stays stale")
  func midRunFailureRecordsErrorPreservesCheckpointAndStaleness() async throws {
    let fixture = try Store.makeFixture(head: 600_000)
    let account = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    try await fixture.seedFreshState(for: [account])
    await fixture.store.loadInitialState()
    // Windows [0, 249_999] and [250_000, 499_999] apply-and-checkpoint; the
    // third window's fetch (fromBlock 500_000) fails.
    fixture.chain.failTransfers(forFromBlock: 500_000)

    await fixture.store.syncAccounts([account])

    let state = try #require(
      try await fixture.backend.walletSyncState.load(accountId: account.id))
    // Error surfaced, resume point preserved at the 2nd window's end…
    #expect(state.lastError != nil)
    #expect(state.lastSyncedBlockNumber == 499_999)
    // …but `lastSyncedAt` stays the pre-cycle value, so the stale-check still
    // treats the account as overdue and retries it on the next tick (rather
    // than the per-window `now` the completed windows wrote).
    #expect(state.lastSyncedAt == .distantPast)
    #expect(fixture.store.progressPerAccount[account.id] == nil)
  }

  @Test("A mid-run failure still feeds the pre-failure survivors to detection")
  func midRunFailureStillFeedsSurvivorsToDetection() async throws {
    let fixture = try Store.makeFixture(head: 600_000)
    let account = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    try await fixture.seedFreshState(for: [account])
    await fixture.store.loadInitialState()
    // Inbound ERC-20 in the first window [0, 249_999]; fail the third window.
    fixture.chain.setRows(
      [
        Store.inboundERC20(
          hash: "0xearly", to: Store.walletA, contractAddress: "0xtoken", blockNum: 100_000)
      ],
      forFromBlock: 0)
    fixture.chain.failTransfers(forFromBlock: 500_000)

    let fetchAllBefore = await fixture.recorder.fetchAllCallCount
    await fixture.store.syncAccounts([account])
    let detectionPasses = await fixture.recorder.fetchAllCallCount - fetchAllBefore

    // The early window's transfer is persisted AND reached transfer detection
    // (a single pass ran over the non-empty survivor union) despite the later
    // window failing — proving the runner returns pre-failure survivors on the
    // error path rather than discarding them. Without that, `genuinelyNew`
    // would be empty and detection would early-return (zero fetchAll).
    #expect(detectionPasses == 1)
    let txns = try await fixture.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(txns.count == 1)
    let state = try #require(
      try await fixture.backend.walletSyncState.load(accountId: account.id))
    #expect(state.lastError != nil)
    #expect(state.lastSyncedBlockNumber == 499_999)
  }

  // MARK: - Same-cycle cross-account transfer is auto-merged, not suggested

  @Test("A transfer between two direct-path accounts is auto-merged into one transfer")
  func crossAccountTransferMergedAcrossWindowedAccounts() async throws {
    let fixture = try Store.makeFixture(head: 100_000)
    let accountA = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    let accountB = fixture.seedCryptoAccount(walletAddress: Store.walletB)
    try await fixture.seedFreshState(for: [accountA, accountB])
    // One on-chain ERC-20 transfer A → B. Both wallets' scans see the same
    // log (same hash → same externalId): A as outbound (.expense), B as
    // inbound (.income). The two sides land in separate per-account windowed
    // applies, so the same-cycle reconciliation (restored on the windowed
    // path) collapses the certain pair into one two-`.transfer`-leg transfer
    // BEFORE the fuzzy detection pass runs.
    fixture.chain.setRowsForAnyCall([
      makeAlchemyTransfer(
        hash: "0xtransfer", from: Store.walletA, to: Store.walletB, category: .erc20,
        contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(50_000))
    ])
    await fixture.store.loadInitialState()

    let fetchAllBefore = await fixture.recorder.fetchAllCallCount
    await fixture.store.syncAccounts([accountA, accountB])
    let detectionPasses = await fixture.recorder.fetchAllCallCount - fetchAllBefore

    // The certain pair was collapsed BEFORE detection, so the merged transfer
    // carries a nil `transferDetectionValueLeg` and nothing eligible remains —
    // the fuzzy pass short-circuits before any counterpart `fetchAll`.
    #expect(detectionPasses == 0)

    // Exactly one merged transfer survives, carrying both accounts' legs as
    // two `.transfer` legs.
    let txns = try await fixture.backend.transactions.fetchAll(filter: TransactionFilter())
    #expect(txns.count == 1)
    let merged = try #require(txns.first)
    let transferLegs = merged.legs.filter { $0.type == .transfer }
    #expect(transferLegs.count == 2)
    let legAccounts = Set(transferLegs.compactMap(\.accountId))
    #expect(legAccounts == Set([accountA.id, accountB.id]))
    let valueLegs = merged.legs.filter { $0.externalId == "0xtransfer:0" }
    #expect(valueLegs.count == 2)

    // The pair was collapsed at merge time, so the fuzzy pass wrote NO
    // suggestion.
    let suggestions = try await fixture.backend.transferSuggestions.fetchAll()
    #expect(suggestions.isEmpty)
  }
}
