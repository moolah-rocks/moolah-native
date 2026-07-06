// MoolahTests/Shared/CryptoImport/WindowedWalletSyncResumeTests.swift
import Foundation
import Testing

@testable import Moolah

/// End-to-end interruption → resume → completeness regression for the
/// windowed direct-RPC sync runner. `WindowedWalletSyncRunnerTests` covers
/// each behaviour (empty-window checkpoint advance, per-window failure,
/// resume start point, idempotent replay) in isolation; this suite chains
/// them into the single scenario a real interruption produces in production:
/// a multi-window scan throws mid-scan, and the very next sync cycle resumes
/// from the durable checkpoint and completes to `head` without re-creating
/// any transaction the interrupted run already persisted.
@Suite("WindowedWalletSyncRunner — interruption / resume / completeness")
@MainActor
struct WindowedWalletSyncResumeTests {
  @Test(
    """
    A mid-scan throw checkpoints at the last completed window (not `from`); \
    the next run resumes from checkpoint − 32, completes to head, and \
    produces no duplicate transactions
    """)
  func interruptionThenResumeCompletesWithoutDuplicates() async throws {
    let setup = try WindowedRunnerFixture.make(head: 600_000)
    let account = setup.seedAccount()
    let wallet = WindowedRunnerFixture.wallet
    let counterparty = WindowedRunnerFixture.counterparty

    // Window 1 [0, 249_999]: one inbound ERC-20, only returned on window 1's
    // own fetch.
    let windowOneTransfer = makeAlchemyTransfer(
      hash: "0xw1", from: counterparty, to: wallet, category: .erc20,
      contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(100_000))
    setup.chain.setRows([windowOneTransfer], forFromBlock: 0)

    // Window 2 [250_000, 499_999]: one inbound ERC-20 near the window's end —
    // inside the reorg zone (499_967...499_999) the resumed run re-scans. The
    // chain still reports the same on-chain transfer there on resume
    // (nothing changed on-chain), so the apply pass must dedup it rather
    // than double-persist.
    let windowTwoTransfer = makeAlchemyTransfer(
      hash: "0xw2", from: counterparty, to: wallet, category: .erc20,
      contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(499_990))
    setup.chain.setRows([windowTwoTransfer], forFromBlock: 250_000)
    setup.chain.setRows([windowTwoTransfer], forFromBlock: 499_967)

    // Window 3 [500_000, 600_000] fails — models a mid-scan interruption
    // (network drop, cancellation, app quit) after two windows completed.
    setup.chain.failTransfers(forFromBlock: 500_000)

    // --- First run: interrupted mid-scan ---
    let firstResult = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(firstResult.windowError != nil)
    #expect(firstResult.genuinelyNew.count == 2)
    let checkpointAfterFirstRun = try #require(
      try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    ).lastSyncedBlockNumber
    // The checkpoint sits at the second (last completed) window's end — NOT
    // the original `from` (0) the scan started at.
    #expect(checkpointAfterFirstRun == 499_999)
    let stateAfterFirstRun = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(stateAfterFirstRun?.lastSyncedBlockNumber == 499_999)
    let persistedAfterFirstRun = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(persistedAfterFirstRun.count == 2)

    // --- Second run: failure cleared, resumes and completes ---
    setup.chain.clearFailures()
    let callsBeforeResume = setup.chain.recordedFromBlocks.count

    let secondResult = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(secondResult.windowError == nil)
    let resumeFromBlocks = Array(setup.chain.recordedFromBlocks.dropFirst(callsBeforeResume))
    // Resumes from checkpoint − 32 — not the top of the range, and not a
    // re-scan of window 1.
    #expect(resumeFromBlocks.first == checkpointAfterFirstRun - WindowedRunnerFixture.reorgWindow)
    #expect(resumeFromBlocks == [499_967])

    let checkpointAfterSecondRun = try #require(
      try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    ).lastSyncedBlockNumber
    #expect(checkpointAfterSecondRun == 600_000)  // completes to head
    let stateAfterSecondRun = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(stateAfterSecondRun?.lastSyncedBlockNumber == 600_000)

    // No duplicates: window 2's transfer reappears in the reorg re-scan but
    // dedups by (accountId, externalId), so the second run contributes no
    // genuinely-new transactions and the total count stays at 2, not 3.
    #expect(secondResult.genuinelyNew.isEmpty)
    let persistedAfterSecondRun = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(persistedAfterSecondRun.count == 2)
    let externalIds = Set(persistedAfterSecondRun.flatMap { $0.legs.compactMap(\.externalId) })
    #expect(externalIds.contains("0xw1:0"))
    #expect(externalIds.contains("0xw2:0"))
  }
}
