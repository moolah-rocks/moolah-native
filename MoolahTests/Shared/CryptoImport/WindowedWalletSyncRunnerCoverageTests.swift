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

  @Test("from > head reports .scanning(1.0) without any fetch, apply, or checkpoint write")
  func alreadyCaughtUpSkipsFetchApplyAndCheckpoint() async throws {
    let blockscout = RecordingBlockExplorerClientStub()
    let setup = try WindowedRunnerFixture.make(head: 100_000, blockExplorer: blockscout)
    let account = setup.seedAccount()
    // A local checkpoint high enough that the reorg-adjusted `fromBlock`
    // (checkpoint − 32) still exceeds `head` — models a peer's synced
    // checkpoint racing ahead of this device's freshly-observed head.
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
    // No fetch, no apply, no checkpoint write: the guard returns before any
    // I/O beyond the pre-loop reads — including the native-context fetch,
    // which a codepath that fell through to `WalletSyncWindowMath.windows`
    // returning empty (rather than this guard) would still have triggered.
    #expect(blockscout.recordedNativeCalls.isEmpty)
    #expect(blockscout.recordedInternalCalls.isEmpty)
    #expect(setup.chain.recordedFromBlocks.isEmpty)
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint == nil)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 200_000)  // unchanged from the seed
  }
}
