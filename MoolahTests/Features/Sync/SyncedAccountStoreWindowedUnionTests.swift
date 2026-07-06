// MoolahTests/Features/Sync/SyncedAccountStoreWindowedUnionTests.swift
import Foundation
import Testing

@testable import Moolah

/// Verifies `SyncedAccountStore` runs transfer detection exactly once per sync
/// cycle over the UNION of the windowed runner's survivors and the single-shot
/// batch's survivors — the cross-path invariant the windowed routing must
/// preserve. Shares the harness in `WindowedSyncStore.swift`.
@Suite("SyncedAccountStore — windowed + single-shot union")
@MainActor
struct SyncedAccountStoreWindowedUnionTests {
  private typealias Store = WindowedSyncStore

  @Test("Detection runs once over the union of windowed and single-shot survivors")
  func detectionRunsOnceOverWindowedAndSingleShotUnion() async throws {
    let fixture = try Store.makeFixture(head: 100_000)
    // Windowed crypto account (resolvable chain → windowed runner).
    let cryptoAccount = fixture.seedCryptoAccount(walletAddress: Store.walletA)
    try await fixture.seedFreshState(for: [cryptoAccount])
    fixture.chain.setRowsForAnyCall([
      Store.inboundERC20(
        hash: "0xcrypto", to: Store.walletA, contractAddress: "0xtoken", blockNum: 50_000)
    ])
    // Exchange account (no chainId → single-shot path). Registered after
    // construction because it uses harness-owned collaborators.
    let exchangeAccount = try Store.seedExchangeDepositSource(
      in: fixture, token: "TOK", deposits: 250)
    try await fixture.seedFreshState(for: [exchangeAccount])
    await fixture.store.loadInitialState()

    let fetchAllBefore = await fixture.recorder.fetchAllCallCount
    await fixture.store.syncAccounts([cryptoAccount, exchangeAccount])
    let detectionPasses = await fixture.recorder.fetchAllCallCount - fetchAllBefore

    // A single detection pass covered both the windowed crypto survivor and
    // the single-shot exchange survivor.
    #expect(detectionPasses == 1)
    let txns = try await fixture.backend.transactions.fetchAll(filter: TransactionFilter())
    let cryptoTxns = txns.filter { $0.accountIds.contains(cryptoAccount.id) }
    let exchangeTxns = txns.filter { $0.accountIds.contains(exchangeAccount.id) }
    #expect(cryptoTxns.count == 1)
    #expect(exchangeTxns.count == 1)
  }
}
