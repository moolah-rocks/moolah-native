// MoolahTests/Shared/CryptoImport/WindowedWalletSyncRunnerCoverageTests.swift
import Foundation
import Testing

@testable import Moolah

/// Coverage for two `WindowedWalletSyncRunner` behaviours the
/// `WindowedWalletSyncRunnerTests` suite doesn't reach:
///
/// - A non-empty native (Blockscout) row surviving `WalletSyncWindowMath.partition`
///   into its own window and flowing through `buildWindow` into a real
///   apply/persist — every `WindowedWalletSyncRunnerTests` case wires an empty
///   Blockscout double, so none of them exercise the native partition.
/// - The `from > head` "already caught up" guard, where a peer's synced
///   checkpoint sits ahead of this device's freshly-observed head.
@Suite("WindowedWalletSyncRunner — native partition + already-caught-up guard")
@MainActor
struct WindowedWalletSyncRunnerCoverageTests {
  @Test(
    """
    A non-empty native Blockscout row for a later window flows through \
    buildWindow into apply and persists only once that window completes
    """)
  func nativeRowPartitionsIntoItsOwnWindowAndPersists() async throws {
    let blockscout = RecordingBlockExplorerClientStub()
    // One native ETH transfer at block 300_000 — inside window 2's range
    // [250_000, 499_999], not window 1's [0, 249_999].
    blockscout.setNative(
      .txs([
        BlockscoutTransaction(
          hash: "0xnative", blockNumber: 300_000, timestamp: "2024-09-12T12:00:00.000000Z",
          from: .init(hash: WindowedRunnerFixture.counterparty),
          to: .init(hash: WindowedRunnerFixture.wallet),
          value: "1000000000000000000", status: "ok", result: "success")
      ]))
    let setup = try WindowedRunnerFixture.make(head: 600_000, blockExplorer: blockscout)
    let account = setup.seedAccount()
    // At the moment window 2's own ERC-20 fetch begins (the 2nd call), window
    // 1 has already applied-and-checkpointed but must NOT have persisted the
    // native row — proving `WalletSyncWindowMath.partition` kept it out of
    // window 1's slice rather than leaking it into every window.
    setup.chain.setOnGetAssetTransfers {
      if setup.chain.recordedFromBlocks.count == 2 {
        let persistedSoFar = try? await setup.backend.transactions.fetchAll(filter: .init())
        #expect(persistedSoFar?.isEmpty == true)
      }
    }

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(result.didWindowedScan)
    #expect(result.windowError == nil)
    // The native context is fetched once up front for the whole range, not
    // once per window.
    #expect(blockscout.recordedNativeCalls.count == 1)
    #expect(blockscout.recordedNativeCalls.first?.fromBlock == 0)
    let persisted = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(persisted.count == 1)
    let externalIds = persisted.flatMap { $0.legs.compactMap(\.externalId) }
    #expect(externalIds.contains("0xnative:external:0"))
  }

  @Test(
    """
    from > head reports .scanning(1.0) without a scan fetch, but still refreshes \
    lastSyncedAt WITHOUT lowering lastSyncedBlockNumber
    """)
  func alreadyCaughtUpRefreshesLastSyncedAtWithoutLoweringBlock() async throws {
    let blockscout = RecordingBlockExplorerClientStub()
    let setup = try WindowedRunnerFixture.make(head: 100_000, blockExplorer: blockscout)
    let account = setup.seedAccount()
    // A local checkpoint high enough that the reorg-adjusted `fromBlock`
    // (checkpoint − 32) still exceeds `head` — models a peer's synced
    // checkpoint racing ahead of this device's freshly-observed head. Seed a
    // stale `lastSyncedAt` so the refresh is observable.
    try await setup.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 200_000,
        lastSyncedAt: .distantPast, lastError: nil))

    var progressCalls: [WalletSyncProgress] = []
    let result = try await setup.runner.run(
      account: account, chain: .ethereum
    ) { progressCalls.append($0) }

    #expect(result.didWindowedScan)
    #expect(result.windowError == nil)
    #expect(result.genuinelyNew.isEmpty)
    #expect(progressCalls.count == 1)
    let onlyProgress = try #require(progressCalls.first)
    guard case let .scanning(fraction) = onlyProgress else {
      Issue.record("Expected .scanning progress, got \(onlyProgress)")
      return
    }
    #expect(fraction == 1.0)
    // No scan fetch: the guard returns before any window I/O — no
    // native-context fetch, no ERC-20 window scan.
    #expect(blockscout.recordedNativeCalls.isEmpty)
    #expect(blockscout.recordedInternalCalls.isEmpty)
    #expect(setup.chain.recordedFromBlocks.isEmpty)
    // But it DOES apply an empty input at the prior checkpoint so the account
    // isn't left perpetually stale: `lastSyncedAt` refreshes to `now`, the
    // block number stays put (NOT lowered to the reorg-subtracted `from`),
    // and the synced checkpoint is raised to (not below) the prior value.
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 200_000)  // unchanged, not lowered
    #expect(state?.lastSyncedAt == WindowedRunnerFixture.pinnedNow)  // refreshed
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 200_000)
  }

  @Test(
    """
    An outbound signed tx in a LATER window gets its gas leg ON the transfer \
    transaction in that window — no phantom gas-only tx in an earlier window, \
    and the receipt is fetched once, not once per window
    """)
  func outboundGasLegLandsInItsOwnWindowNotAsAnEarlierPhantom() async throws {
    let blockscout = RecordingBlockExplorerClientStub()
    // One OUTBOUND native ETH send at block 300_000 — inside window 2's range
    // [250_000, 499_999], not window 1's [0, 249_999]. Because the wallet is
    // the sender, this yields BOTH an external transfer AND a signed-gas tx,
    // each stamped at block 300_000.
    let hash = "0xoutbound"
    blockscout.setNative(
      .txs([
        BlockscoutTransaction(
          hash: hash, blockNumber: 300_000, timestamp: "2024-09-12T12:00:00.000000Z",
          from: .init(hash: WindowedRunnerFixture.wallet),
          to: .init(hash: WindowedRunnerFixture.counterparty),
          value: "1000000000000000000", status: "ok", result: "success")
      ]))
    let setup = try WindowedRunnerFixture.make(head: 600_000, blockExplorer: blockscout)
    let account = setup.seedAccount()
    // A real receipt whose `from` matches the wallet so `makeGasLeg` forms a
    // genuine gas leg (21_000 gas × 1 gwei > 0).
    setup.chain.setReceipt(
      AlchemyTransactionReceipt(
        hash: hash, gasUsed: Decimal(21_000),
        effectiveGasPrice: Decimal(1_000_000_000), from: WindowedRunnerFixture.wallet),
      forHash: hash)

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(result.didWindowedScan)
    #expect(result.windowError == nil)

    // Exactly ONE transaction: the outbound transfer carrying its own gas leg.
    // The unpartitioned code synthesised a SECOND, phantom gas-only tx in
    // window 1 (whose "<hash>:gas" leg then deduped the real transfer's gas
    // leg out of window 2), leaving two transactions.
    let persisted = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(persisted.count == 1)
    let transaction = try #require(persisted.first)
    let externalIds = transaction.legs.compactMap(\.externalId)
    // Both legs land on the same transaction: the value transfer AND its gas.
    #expect(Set(externalIds) == ["\(hash):external:0", "\(hash):gas"])
    // No orphan gas-only transaction (one whose only leg is the gas leg).
    let gasOnlyTxs = persisted.filter { persistedTx in
      persistedTx.legs.allSatisfy { $0.externalId == "\(hash):gas" }
    }
    #expect(gasOnlyTxs.isEmpty)
    // The receipt for the signed tx is fetched exactly once — not once per
    // window (the unpartitioned code fetched it in window 1's gas-only path
    // AND window 2's transfer path).
    #expect(setup.chain.recordedReceiptCalls.filter { $0 == hash }.count == 1)
  }
}
