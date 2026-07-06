// MoolahTests/Shared/CryptoImport/WindowedWalletSyncRunnerTests.swift
import Foundation
import GRDB
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
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  // `nonisolated` so the nested (nonisolated) `Setup` can reference `wallet`
  // as a default argument without hopping to the main actor.
  nonisolated static let wallet = "0x1111111111111111111111111111111111111111"
  nonisolated static let counterparty = "0x2222222222222222222222222222222222222222"
  /// The reorg window `WalletSyncEngine.resolveFromBlock` subtracts.
  nonisolated static let reorgWindow: UInt64 = 32

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

  @Test("A throw on the 3rd window leaves the checkpoint at the 2nd window's end")
  func midScanThrowCheckpointsPerWindow() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()
    // Fail the third window's ERC-20 fetch (its fromBlock is 500_000).
    setup.chain.failTransfers(forFromBlock: 500_000)

    await #expect(throws: (any Error).self) {
      _ = try await setup.runner.run(
        account: account, chain: .ethereum, progress: { _ in })
    }

    // Windows 1 and 2 applied-then-checkpointed; window 3 threw before its
    // apply. The durable checkpoint is the 2nd window's end, not 0.
    let checkpoint = try await setup.backend.walletSyncCheckpoints.load(accountId: account.id)
    #expect(checkpoint?.lastSyncedBlockNumber == 499_999)
    let state = try await setup.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastSyncedBlockNumber == 499_999)
  }

  // MARK: - Resume

  @Test("A second run resumes at secondCheckpoint − 32, not the top of the range")
  func resumeStartsAtCheckpointMinusReorgWindow() async throws {
    let setup = try makeSetup(head: 600_000)
    let account = setup.seedAccount()
    setup.chain.failTransfers(forFromBlock: 500_000)
    await #expect(throws: (any Error).self) {
      _ = try await setup.runner.run(
        account: account, chain: .ethereum, progress: { _ in })
    }
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

  private struct Setup {
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let chain: ScriptedWindowChainClient
    let runner: WindowedWalletSyncRunner

    func seedAccount(
      walletAddress: String = WindowedWalletSyncRunnerTests.wallet
    ) -> Account {
      let account = makeCryptoAccount(walletAddress: walletAddress, chain: .ethereum)
      _ = TestBackend.seed(accounts: [account], in: database)
      return account
    }
  }

  private func makeSetup(
    head: UInt64?,
    segmentBlockWindow: UInt64 = 250_000
  ) throws -> Setup {
    let (backend, database) = try TestBackend.create()
    let chain = ScriptedWindowChainClient(head: head)
    // Wire discovery to the backend's shared registry (matches production)
    // so an ERC-20 instrument the engine resolves is registered where the
    // apply pass's persistence reads it back.
    let discovery = CryptoTokenDiscoveryService(
      registry: backend.grdbInstruments, resolver: CountingRegistrationResolver())
    let engine = WalletSyncEngine(
      alchemy: chain,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importOriginFactory: { makeWalletImportOrigin(for: $0) })
    let applyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    let runner = WindowedWalletSyncRunner(
      engine: engine,
      chainClient: chain,
      applyEngine: applyEngine,
      segmentBlockWindow: segmentBlockWindow)
    return Setup(backend: backend, database: database, chain: chain, runner: runner)
  }
}

/// Scriptable, recording `ChainDataClient` for the windowed-runner tests.
/// Returns a fixed `currentHead`, per-`fromBlock` ERC-20 rows (or a single
/// set for every call), records every `getAssetTransfers` `fromBlock`, and
/// can inject a failure on a chosen window's fetch. Receipts return a
/// zero-fee sentinel (`from: ""`) so an outbound transfer's gas-leg lookup
/// resolves to no leg rather than trapping.
///
/// `@unchecked Sendable`: all mutable state lives behind an `NSLock`,
/// matching the project convention for non-actor concurrent test stubs.
final class ScriptedWindowChainClient: ChainDataClient, @unchecked Sendable {
  /// Thrown by a window scripted to fail via `failTransfers(forFromBlock:)`.
  struct ScriptedWindowFailure: Error { let fromBlock: UInt64 }

  private let lock = NSLock()
  private let head: UInt64?
  private var rowsByFromBlock: [UInt64: [AlchemyTransfer]] = [:]
  private var anyCallRows: [AlchemyTransfer] = []
  private var failingFromBlocks: Set<UInt64> = []
  private var fromBlocks: [UInt64] = []

  init(head: UInt64?) {
    self.head = head
  }

  /// Rows returned for the window whose fetch starts at `fromBlock`.
  func setRows(_ rows: [AlchemyTransfer], forFromBlock fromBlock: UInt64) {
    lock.withLock { rowsByFromBlock[fromBlock] = rows }
  }

  /// Rows returned for every fetch that has no per-`fromBlock` override —
  /// used to model a transfer that reappears in the reorg-window re-scan.
  func setRowsForAnyCall(_ rows: [AlchemyTransfer]) {
    lock.withLock { anyCallRows = rows }
  }

  /// Scripts the fetch for the window starting at `fromBlock` to throw.
  func failTransfers(forFromBlock fromBlock: UInt64) {
    lock.withLock { _ = failingFromBlocks.insert(fromBlock) }
  }

  /// Clears all scripted failures (used to model a cleared transient error
  /// on resume).
  func clearFailures() {
    lock.withLock { failingFromBlocks.removeAll() }
  }

  /// Every `getAssetTransfers` `fromBlock`, in call order.
  var recordedFromBlocks: [UInt64] {
    lock.withLock { fromBlocks }
  }

  func currentHead(chain: ChainConfig) async throws -> UInt64? {
    head
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    toBlock: UInt64?
  ) async throws -> [AlchemyTransfer] {
    let (rows, shouldFail) = lock.withLock { () -> ([AlchemyTransfer], Bool) in
      fromBlocks.append(fromBlock)
      let resolved = rowsByFromBlock[fromBlock] ?? anyCallRows
      return (resolved, failingFromBlocks.contains(fromBlock))
    }
    if shouldFail { throw ScriptedWindowFailure(fromBlock: fromBlock) }
    return rows
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    // Sentinel `from: ""` never matches a wallet, so `makeGasLeg` returns
    // nil and no gas leg is synthesised — keeps the transfer legs the
    // tests inspect deterministic.
    AlchemyTransactionReceipt(hash: hash, gasUsed: 0, effectiveGasPrice: 0, from: "")
  }
}
