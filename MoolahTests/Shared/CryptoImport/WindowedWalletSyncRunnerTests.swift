// MoolahTests/Shared/CryptoImport/WindowedWalletSyncRunnerTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `WindowedWalletSyncRunner` — the resumable,
/// determinate direct-RPC sync loop. Wires a REAL `WalletApplyEngine` over
/// an in-memory GRDB backend so the checkpoint / `WalletSyncState` writes
/// are genuine (the whole point of the feature is that an interrupted scan
/// leaves a correct, resumable checkpoint). The `ChainDataClient` is a
/// scripted stub that returns per-window ERC-20 rows, records every
/// `fromBlock`, and can inject a failure on a chosen window.
@Suite("WindowedWalletSyncRunner — windowed scan / apply / checkpoint")
@MainActor
struct WindowedWalletSyncRunnerTests {
  // Re-exported from the shared `WindowedRunnerFixture` so the test bodies
  // below read `Self.wallet` etc. without re-declaring the values.
  nonisolated static let wallet = WindowedRunnerFixture.wallet
  nonisolated static let counterparty = WindowedRunnerFixture.counterparty
  nonisolated static let reorgWindow = WindowedRunnerFixture.reorgWindow

  // MARK: - Empty windows advance the checkpoint

  @Test("Empty windows still advance the checkpoint and local state to head")
  func emptyWindowsAdvanceCheckpoint() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(result.didWindowedScan)
    #expect(result.genuinelyNew.isEmpty)
    // Three windows: [0, 249_999], [250_000, 499_999], [500_000, 600_000].
    #expect(setup.chain.recordedFromBlocks == [0, 250_000, 500_000])
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 600_000)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 600_000)
  }

  // MARK: - Per-window checkpoint on a mid-scan throw

  @Test("A per-window failure surfaces windowError and checkpoints at the 2nd window's end")
  func midScanFailureReturnsErrorAndCheckpointsPerWindow() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()
    // Fail the third window's ERC-20 fetch (its fromBlock is 500_000).
    setup.chain.failTransfers(forFromBlock: 500_000)

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    // Windows 1 and 2 applied-then-checkpointed; window 3 failed before its
    // apply. The run does NOT throw on a per-window error — it stops and
    // surfaces the error so the caller can still consume the survivors.
    #expect(result.didWindowedScan)
    #expect(result.windowError != nil)
    // The durable checkpoint is the 2nd window's end, not 0.
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 499_999)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 499_999)
  }

  @Test("A per-window failure still returns the survivors from earlier windows")
  func midScanFailureReturnsPreFailureSurvivors() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()
    // One inbound ERC-20 in the first window [0, 249_999]; fail the third.
    setup.chain.setRows(
      [
        makeAlchemyTransfer(
          hash: "0xearly", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(100_000))
      ],
      forFromBlock: 0)
    setup.chain.failTransfers(forFromBlock: 500_000)

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(result.windowError != nil)
    // The first window's persisted transfer is returned despite the later
    // failure, so transfer detection still sees it (the whole point of the
    // return-on-error contract).
    #expect(result.genuinelyNew.count == 1)
    let persisted = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(persisted.count == 1)
  }

  // MARK: - Mid-scan cancellation returns survivors, not an error

  @Test("Mid-scan cancellation returns the pre-cancel survivors without an error")
  func midScanCancellationReturnsSurvivorsWithoutError() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()
    // Inbound ERC-20 in the first window [0, 249_999].
    setup.chain.setRows(
      [
        makeAlchemyTransfer(
          hash: "0xearly", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(100_000))
      ],
      forFromBlock: 0)
    // Cancel the run once the SECOND window's fetch begins — window 1 has by
    // then fully applied-and-checkpointed its transfer. `withUnsafeCurrentTask`
    // cancels the child task the run executes in (below), not the test task.
    setup.chain.setOnGetAssetTransfers {
      if setup.chain.recordedFromBlocks.count == 2 {
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }

    let result = try await Task { @MainActor in
      try await setup.runner.run(account: account, chain: .ethereum, progress: { _ in })
    }.value

    // Cancellation is not an error: no `windowError`, so the caller writes no
    // `lastError` — but the first window's persisted survivor is still returned
    // so this cycle's detection pass (which runs regardless of cancellation)
    // sees it.
    #expect(result.didWindowedScan)
    #expect(result.windowError == nil)
    #expect(result.genuinelyNew.count == 1)
    let persisted = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(persisted.count == 1)
    // The checkpoint sits at a completed window (at least the first's end).
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect((checkpoint?.lastSyncedBlockNumber ?? 0) >= 249_999)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastError == nil)
  }

  // MARK: - Resume

  @Test("A second run resumes at secondCheckpoint − 32, not the top of the range")
  func resumeStartsAtCheckpointMinusReorgWindow() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()
    setup.chain.failTransfers(forFromBlock: 500_000)
    let firstResult = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })
    #expect(firstResult.windowError != nil)
    let secondCheckpoint = try #require(
      try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    ).lastSyncedBlockNumber
    #expect(secondCheckpoint == 499_999)

    // Clear the failure and resume; the first fetch of the second run must
    // start from the checkpoint minus the reorg window — it does NOT
    // re-scan window 1 from 0.
    let callsBeforeResume = setup.chain.recordedFromBlocks.count
    setup.chain.clearFailures()

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(result.didWindowedScan)
    let resumeFromBlocks = Array(setup.chain.recordedFromBlocks.dropFirst(callsBeforeResume))
    #expect(resumeFromBlocks.first == secondCheckpoint - Self.reorgWindow)  // 499_967
    // 499_967…600_000 fits one window, so exactly one resume fetch.
    #expect(resumeFromBlocks == [499_967])
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 600_000)
  }

  // MARK: - Apply-before-checkpoint / idempotent replay

  @Test("Re-running over an already-applied transfer produces no duplicate")
  func idempotentReplayNoDuplicate() async throws {
    let setup = try makeSetup(head: 100_000)
    let account = setup.seedAccount()
    // One inbound ERC-20 at the head block, returned on every fetch so both
    // the first pass and the reorg-window re-scan see it.
    setup.chain.setRowsForAnyCall([
      makeAlchemyTransfer(
        hash: "0xreplay", from: Self.counterparty, to: Self.wallet, category: .erc20,
        contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(100_000))
    ])

    let first = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })
    #expect(first.genuinelyNew.count == 1)
    let afterFirst = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(afterFirst.count == 1)

    // Second run re-scans [100_000 − 32, 100_000] and re-fetches the same
    // row; the apply pass dedups by (accountId, externalId) → no duplicate.
    let second = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })
    #expect(second.genuinelyNew.isEmpty)
    let afterSecond = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(afterSecond.count == 1)
  }

  // MARK: - Progress monotonic 0 → 1

  @Test("Progress is monotonic non-decreasing, starting at 0 and ending at 1")
  func progressMonotonicZeroToOne() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()

    var fractions: [Double] = []
    _ = try await setup.runner.run(account: account, chain: .ethereum) { progress in
      guard case let .scanning(fraction) = progress else { return }
      fractions.append(fraction)
    }

    #expect(fractions.first == 0.0)
    #expect(fractions.last == 1.0)
    let nonDecreasing = zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }
    #expect(nonDecreasing)
  }

  // MARK: - Alchemy fallback (no head)

  @Test("A nil currentHead returns didWindowedScan == false and writes nothing")
  func nilHeadFallsBackWithoutWriting() async throws {
    let setup = try makeSetup(head: nil)
    let account = setup.seedAccount()

    var progressCalls = 0
    let result = try await setup.runner.run(account: account, chain: .ethereum) { _ in
      progressCalls += 1
    }

    #expect(result.didWindowedScan == false)
    #expect(result.genuinelyNew.isEmpty)
    #expect(progressCalls == 0)
    // No scan, no apply, no checkpoint.
    #expect(setup.chain.recordedFromBlocks.isEmpty)
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint == nil)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state == nil)
  }

  // MARK: - Lower-of-two-topics never checkpoints beyond the window end

  @Test("A window whose inbound log outblocks the outbound still checkpoints to window end")
  func checkpointIsWindowEndNotMaxObservedBlock() async throws {
    let setup = try makeSetup(head: 200_000)
    let account = setup.seedAccount()
    // Outbound (from-pass) log at a low block; inbound (to-pass) log at a
    // higher block — both inside the single window [0, 200_000]. The
    // checkpoint must be the window end (200_000), not the max observed
    // block (150_000) and never beyond the window end.
    setup.chain.setRowsForAnyCall([
      makeAlchemyTransfer(
        hash: "0xoutbound", from: Self.wallet, to: Self.counterparty, category: .erc20,
        contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(100)),
      makeAlchemyTransfer(
        hash: "0xinbound", from: Self.counterparty, to: Self.wallet, category: .erc20,
        contractAddress: "0xtoken", blockNum: RPCHex.hexQuantity(150_000)),
    ])

    let result = try await setup.runner.run(
      account: account, chain: .ethereum, progress: { _ in })

    #expect(result.didWindowedScan)
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 200_000)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 200_000)
  }

  // MARK: - Helpers

  /// Thin alias onto the shared `WindowedRunnerFixture.make` so this suite's
  /// call sites read `makeSetup(head:)` while the runner wiring lives in one
  /// place (also consumed by `WindowedWalletSyncResumeTests` and
  /// `WindowedWalletSyncRunnerCoverageTests`).
  private func makeSetup(
    head: UInt64?,
    segmentBlockWindow: UInt64 = 250_000
  ) throws -> WindowedRunnerFixture.Setup {
    try WindowedRunnerFixture.make(head: head, segmentBlockWindow: segmentBlockWindow)
  }
}
