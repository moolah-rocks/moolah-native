// MoolahTests/Features/Crypto/SyncedAccountStorePipelineStructureTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Asserts the *structural* property of the wallet-sync pipeline that
/// `CrossAccountTransferMergerTests` only checks indirectly via merged
/// outcomes: the cross-account merger runs **exactly once** per sync,
/// **after** the parallel build TaskGroup has completed, with the
/// **union** of every participating account's candidates.
///
/// If a future refactor moved the apply pass inside the per-account
/// TaskGroup (one merger call per account, each with partial input),
/// `CrossAccountTransferMergerTests`'s outcome assertions would still
/// pass for unmergeable inputs and only fail probabilistically on the
/// mergeable cases. This test makes the structural contract explicit
/// using a recording merger that captures every invocation.
@Suite("SyncedAccountStore — pipeline structure")
@MainActor
struct SyncedAccountStorePipelineStructureTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  static let counterparty = "0x9999999999999999999999999999999999999999"

  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
    let merger: RecordingCrossAccountTransferMerger
  }

  private func makeFixture() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    // Resolve through the backend's shared profile-index registry;
    // there is no per-profile `instrument` table.
    let registry = backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver())
    let checkpoints = InMemoryWalletSyncCheckpointRepository()
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      checkpoints: checkpoints,
      importOriginFactory: { accountId in
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: UUID(),
          parserIdentifier: "alchemy-wallet-sync")
      })
    let merger = RecordingCrossAccountTransferMerger()
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      checkpoints: checkpoints,
      importRules: NoOpWalletImportRulesEngine(),
      merger: merger,
      clock: { Self.pinnedNow })
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      walletSyncCheckpoints: checkpoints,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow },
      staleThreshold: 86_400,
      timerInterval: .seconds(3_600),
      maxConcurrentBuilds: 4)
    return Fixture(
      store: store, backend: backend, database: database, alchemy: alchemy, merger: merger)
  }

  @Test("Merger is called exactly once with the union of every account's candidates")
  func mergerSeesUnionAfterParallelBuilds() async throws {
    let fixture = try makeFixture()
    // Two distinct wallets; each receives one inbound transfer with its
    // own hash so both per-account builds produce a candidate without
    // pairing into a merged transaction (we're testing the *call shape*,
    // not the merge outcome).
    let walletA = "0x1111111111111111111111111111111111111111"
    let walletB = "0x2222222222222222222222222222222222222222"
    let accountA = seedCryptoAccount(in: fixture.database, walletAddress: walletA)
    let accountB = seedCryptoAccount(in: fixture.database, walletAddress: walletB)
    // Use erc20 so transfers survive the Alchemy filter (native ETH is
    // now sourced from Blockscout; Alchemy only passes erc20).
    fixture.alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: walletA, category: .erc20,
          contractAddress: "0xtoken1", decimalsHex: "0x12")
      ]),
      for: walletA)
    fixture.alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xb", from: Self.counterparty, to: walletB, category: .erc20,
          contractAddress: "0xtoken2", decimalsHex: "0x12")
      ]),
      for: walletB)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: accountA.id, lastSyncedBlockNumber: 0, lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: accountB.id, lastSyncedBlockNumber: 0, lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncStaleAccounts()

    let invocations = fixture.merger.invocations
    #expect(invocations.count == 1)
    let invocation = try #require(invocations.first)
    let originIds = Set(invocation.candidates.map(\.originAccountId))
    #expect(originIds == Set([accountA.id, accountB.id]))
  }

  @Test("Throttling one build doesn't split the merger call into two")
  func throttledBuildStillProducesSingleMergerCall() async throws {
    let fixture = try makeFixture()
    let walletA = "0x3333333333333333333333333333333333333333"
    let walletB = "0x4444444444444444444444444444444444444444"
    let accountA = seedCryptoAccount(in: fixture.database, walletAddress: walletA)
    let accountB = seedCryptoAccount(in: fixture.database, walletAddress: walletB)
    // Use erc20 so transfers survive the Alchemy filter (native ETH is
    // now sourced from Blockscout; Alchemy only passes erc20).
    fixture.alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xc", from: Self.counterparty, to: walletA, category: .erc20,
          contractAddress: "0xtoken3", decimalsHex: "0x12")
      ]),
      for: walletA)
    fixture.alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xd", from: Self.counterparty, to: walletB, category: .erc20,
          contractAddress: "0xtoken4", decimalsHex: "0x12")
      ]),
      for: walletB)
    // Delay every Alchemy fetch a touch so the two per-account builds
    // genuinely interleave on the TaskGroup. The structural guarantee is
    // independent of completion order — the apply pass must not run
    // until both have returned regardless.
    fixture.alchemy.setBeforeAssetTransfers {
      try? await Task.sleep(for: .milliseconds(20))
    }
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: accountA.id, lastSyncedBlockNumber: 0, lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: accountB.id, lastSyncedBlockNumber: 0, lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncStaleAccounts()

    let invocations = fixture.merger.invocations
    #expect(invocations.count == 1)
    let invocation = try #require(invocations.first)
    let originIds = Set(invocation.candidates.map(\.originAccountId))
    #expect(originIds == Set([accountA.id, accountB.id]))
  }

  /// Seeds a crypto account directly into GRDB.
  private func seedCryptoAccount(
    in database: DatabaseQueue,
    walletAddress: String,
    chain: ChainConfig = .ethereum
  ) -> Account {
    let account = Account(
      name: "Wallet \(walletAddress.suffix(4))",
      type: .crypto,
      instrument: chain.nativeInstrument,
      valuationMode: .calculatedFromTrades,
      walletAddress: walletAddress.lowercased(),
      chainId: chain.chainId)
    _ = TestBackend.seed(accounts: [account], in: database)
    return account
  }
}
