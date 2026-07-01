// MoolahTests/Shared/CryptoImport/WalletSyncEngineTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `WalletSyncEngine`. Exercises the per-account
/// orchestration: account validation → reorg-window `fromBlock` → Alchemy
/// fetch → builder. Asserts the engine never writes to any repository
/// (the load-bearing parallel-build invariant).
@Suite("WalletSyncEngine — Build phase")
struct WalletSyncEngineTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"

  // MARK: - Helpers

  private func makeEngine(
    alchemy: RecordingAlchemyClientStub = .init(),
    blockExplorer: RecordingBlockExplorerClientStub = BlockExplorerTestDoubles.empty,
    syncState: RecordingWalletSyncStateRepository = .init()
  ) -> (WalletSyncEngine, CryptoTokenDiscoverySubject) {
    let subject = makeDiscoverySubject()
    let engine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: subject.service,
      walletSyncState: syncState,
      importOriginFactory: { accountId in
        makeWalletImportOrigin(for: accountId)
      })
    return (engine, subject)
  }

  // MARK: - Happy path

  @Test("Returns one BuiltTransaction per inbound transfer; no state writes")
  func happyPathReturnsBuiltTransactions() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken1", decimalsHex: "0x12"),
        makeAlchemyTransfer(
          hash: "0xb", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken2", decimalsHex: "0x12"),
        makeAlchemyTransfer(
          hash: "0xc", from: Self.wallet, to: Self.counterparty, category: .erc20,
          contractAddress: "0xtoken3", decimalsHex: "0x12"),
      ]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.build(account: account, chain: .ethereum)

    #expect(result.candidates.count == 3)
    #expect(result.candidates.allSatisfy { $0.originAccountId == account.id })
    // `makeAlchemyTransfer` defaults `blockNum = "0x12d4f0a"` → 19_746_570.
    #expect(result.headBlockNumber == 19_746_570)
    #expect(syncState.saveCount == 0)
    #expect(syncState.deleteCount == 0)
  }

  // MARK: - fromBlock derivation

  @Test("Pre-existing state → fromBlock = lastSyncedBlockNumber - 32")
  func fromBlockSubtractsReorgWindow() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 100,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)

    _ = try await engine.build(account: account, chain: .ethereum)

    let calls = alchemy.recordedCalls
    #expect(calls.count == 1)
    #expect(calls.first?.fromBlock == 68)  // 100 - 32
  }

  @Test("Pre-existing state inside reorg window → fromBlock = 0")
  func fromBlockClampsAtZeroInsideWindow() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 10,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)

    _ = try await engine.build(account: account, chain: .ethereum)
    #expect(alchemy.recordedCalls.first?.fromBlock == 0)
  }

  @Test("No prior state → fromBlock = 0")
  func fromBlockZeroWhenNoState() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    _ = try await engine.build(account: account, chain: .ethereum)
    #expect(alchemy.recordedCalls.first?.fromBlock == 0)
  }

  // MARK: - Cancellation

  @Test("Cancellation between fetch and build throws CancellationError")
  func cancellationBetweenStagesIsRespected() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          // Category is irrelevant: cancellation fires in the Alchemy
          // stub hook before the response returns, so the .erc20
          // filter is never reached.
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .external)
      ]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    // Install the hook *before* creating the build task so the fetch can
    // never outrun hook installation (the flake in #1196: a `Task { }`
    // starts immediately and, under CI load, can reach the Alchemy fetch
    // before the outer thread installs `setBeforeAssetTransfers`, leaving
    // `beforeAssetTransfers` nil and silencing cancellation).
    //
    // The hook parks the fetch inside the Alchemy stub via a two-phase
    // handshake: it signals entry, then suspends until the test has
    // cancelled the task and released it. The stub calls
    // `checkCancellation()` immediately after the hook returns, so
    // cancellation is *always* in effect by then — mirroring real-world
    // cooperative cancellation, deterministically.
    let handshake = CancellationHandshake()
    alchemy.setBeforeAssetTransfers { await handshake.hookEntered() }

    let task = Task<WalletSyncBuildResult, Error> {
      try await engine.build(account: account, chain: .ethereum)
    }
    await handshake.awaitEntry()  // fetch is now parked inside the stub hook
    task.cancel()
    await handshake.release()  // unpark → stub reaches `checkCancellation()`

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  /// Two-phase rendezvous that removes the fetch-vs-hook-install race in
  /// the cancellation test. The Alchemy stub's `beforeAssetTransfers`
  /// hook — installed *before* the build `Task` — calls `hookEntered()`,
  /// which announces the fetch has reached the stub and then parks it
  /// until the test cancels the task and calls `release()`. `awaitEntry()`
  /// lets the test suspend until entry, so cancellation is guaranteed to
  /// land before the stub's post-hook `checkCancellation()`.
  private actor CancellationHandshake {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    /// Called by the stub hook: signals entry, then suspends until
    /// `release()`. Returns immediately if already released.
    func hookEntered() async {
      entered = true
      entryWaiter?.resume()
      entryWaiter = nil
      guard !released else { return }
      await withCheckedContinuation { releaseWaiter = $0 }
    }

    /// Called by the test: suspends until the hook has been entered.
    func awaitEntry() async {
      guard !entered else { return }
      await withCheckedContinuation { entryWaiter = $0 }
    }

    /// Called by the test after cancelling: unparks the stub hook.
    func release() {
      released = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }

  // MARK: - Account validation

  @Test("Non-crypto account → providerMalformedResponse")
  func nonCryptoAccountThrows() async throws {
    let alchemy = RecordingAlchemyClientStub()
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = Account(
      name: "Bank",
      type: .bank,
      instrument: .AUD,
      walletAddress: Self.wallet,
      chainId: 1)

    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(account: account, chain: .ethereum)
    }
    #expect(alchemy.recordedCalls.isEmpty)
  }

  @Test("Missing walletAddress → providerMalformedResponse")
  func missingWalletAddressThrows() async throws {
    let alchemy = RecordingAlchemyClientStub()
    let (engine, _) = makeEngine(alchemy: alchemy)
    var account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    account.walletAddress = nil

    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(account: account, chain: .ethereum)
    }
    #expect(alchemy.recordedCalls.isEmpty)
  }

  @Test("Empty walletAddress → providerMalformedResponse")
  func emptyWalletAddressThrows() async throws {
    let alchemy = RecordingAlchemyClientStub()
    let (engine, _) = makeEngine(alchemy: alchemy)
    var account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    account.walletAddress = ""

    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(account: account, chain: .ethereum)
    }
    #expect(alchemy.recordedCalls.isEmpty)
  }

  // MARK: - Head block

  @Test("Head block is the maximum blockNum across all returned transfers")
  func headBlockTracksMaximumBlockNumber() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet,
          category: .erc20, contractAddress: "0xt1", decimalsHex: "0x12",
          blockNum: "0x10"),  // 16
        makeAlchemyTransfer(
          hash: "0xb", from: Self.counterparty, to: Self.wallet,
          category: .erc20, contractAddress: "0xt2", decimalsHex: "0x12",
          blockNum: "0x20"),  // 32
        makeAlchemyTransfer(
          hash: "0xc", from: Self.counterparty, to: Self.wallet,
          category: .erc20, contractAddress: "0xt3", decimalsHex: "0x12",
          blockNum: "0x18"),  // 24
      ]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.build(account: account, chain: .ethereum)
    #expect(result.headBlockNumber == 32)
  }

  @Test("No transfers + prior checkpoint → head block falls back to prior")
  func headBlockFallsBackToPriorCheckpoint() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 1234,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)

    let result = try await engine.build(account: account, chain: .ethereum)
    #expect(result.headBlockNumber == 1234)
  }

  @Test("No transfers + no prior checkpoint → head block 0")
  func headBlockGenesisFallsBackToZero() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.build(account: account, chain: .ethereum)
    #expect(result.headBlockNumber == 0)
  }

  // MARK: - Read-only invariant

  @Test("End-to-end run never writes to WalletSyncStateRepository")
  func endToEndDoesNotWriteRepositories() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken", decimalsHex: "0x12"),
        makeAlchemyTransfer(
          hash: "0xb", from: Self.wallet, to: Self.counterparty, category: .erc20,
          contractAddress: "0xtoken", decimalsHex: "0x12", uniqueIdSuffix: "1"),
      ]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    _ = try await engine.build(account: account, chain: .ethereum)

    #expect(syncState.saveCount == 0)
    #expect(syncState.deleteCount == 0)
  }
}
