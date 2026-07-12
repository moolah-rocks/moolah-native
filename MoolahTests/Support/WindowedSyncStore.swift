// MoolahTests/Support/WindowedSyncStore.swift
import Foundation
import GRDB

@testable import Moolah

/// Shared harness for the windowed direct-RPC routing suites
/// (`SyncedAccountStoreWindowedSyncTests`, `SyncedAccountStoreWindowedUnionTests`).
///
/// Builds a `SyncedAccountStore` whose windowed runner and single-shot source
/// both read from one `ScriptedWindowChainClient(head:)` — mirroring production,
/// where one routing client feeds both paths — over a REAL `WalletApplyEngine`
/// + in-memory GRDB backend (checkpoint / `WalletSyncState` writes are genuine).
/// A non-nil `head` windows every crypto account; `head == nil` makes the runner
/// report `didWindowedScan == false`, so crypto accounts fall back to the
/// single-shot (Alchemy) path.
enum WindowedSyncStore {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  nonisolated static let walletA = "0x1111111111111111111111111111111111111111"
  nonisolated static let walletB = "0x2222222222222222222222222222222222222222"
  nonisolated static let counterparty = "0x9999999999999999999999999999999999999999"

  struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let chain: ScriptedWindowChainClient
    /// Wraps the backend's transaction repository so tests can count the
    /// single `fetchAll(filter:)` transfer-detection makes per sync cycle.
    let recorder: RecordingTransactionRepository

    func seedCryptoAccount(
      id: UUID = UUID(),
      walletAddress: String,
      chain config: ChainConfig = .ethereum
    ) -> Account {
      let account = makeCryptoAccount(id: id, walletAddress: walletAddress, chain: config)
      _ = TestBackend.seed(accounts: [account], in: database)
      return account
    }

    func seedFreshState(for accounts: [Account]) async throws {
      for account in accounts {
        try await backend.walletSyncState.save(
          WalletSyncState(
            id: account.id, lastSyncedBlockNumber: 0,
            lastSyncedAt: .distantPast, lastError: nil))
      }
    }
  }

  @MainActor
  static func makeFixture(
    head: UInt64?,
    segmentBlockWindow: UInt64 = 250_000
  ) throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let recorder = RecordingTransactionRepository(wrapping: backend.transactions)
    let chain = ScriptedWindowChainClient(head: head)
    let discovery = CryptoTokenDiscoveryService(
      registry: backend.grdbInstruments, resolver: CountingRegistrationResolver())
    let walletSyncEngine = WalletSyncEngine(
      alchemy: chain,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importOriginFactory: { makeWalletImportOrigin(for: $0) })
    let applyEngine = WalletApplyEngine(
      transactions: recorder,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { pinnedNow })
    let runner = WindowedWalletSyncRunner(
      engine: walletSyncEngine,
      chainClient: chain,
      applyEngine: applyEngine,
      segmentBlockWindow: segmentBlockWindow)
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: applyEngine,
      walletSyncState: backend.walletSyncState,
      walletSyncCheckpoints: backend.walletSyncCheckpoints,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: recorder,
        suggestions: backend.transferSuggestions,
        clock: { pinnedNow }),
      clock: { pinnedNow },
      windowedRunner: runner)
    return Fixture(
      store: store, backend: backend, database: database, chain: chain, recorder: recorder)
  }

  /// One inbound ERC-20 transfer to `wallet` at `blockNum`. ERC-20 (not
  /// native ETH) so it survives the wallet engine's native/Blockscout split
  /// without a Blockscout stub.
  static func inboundERC20(
    hash: String,
    to wallet: String,
    contractAddress: String,
    blockNum: UInt64
  ) -> AlchemyTransfer {
    makeAlchemyTransfer(
      hash: hash, from: counterparty, to: wallet, category: .erc20,
      contractAddress: contractAddress, blockNum: RPCHex.hexQuantity(blockNum))
  }

  /// Seeds one `.exchange` account into `fixture` and registers a
  /// `CoinstashSyncSource` that returns a single fiat deposit for `token`. The
  /// deposit is fiat (AUD) so it resolves with no metadata round-trip.
  @MainActor
  static func seedExchangeDepositSource(
    in fixture: Fixture, token: String, deposits amount: Decimal
  ) throws -> Account {
    let account = Account(
      name: "Exchange", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    _ = TestBackend.seed(accounts: [account], in: fixture.database)

    let tokenStore = ExchangeTokenStore(synchronizable: false)
    try tokenStore.save(token: token, for: account.id)

    let registry = fixture.backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: CountingRegistrationResolver())
    let deposit = ExchangeImportedTransaction(
      externalId: "\(token)-deposit-1",
      occurredAt: pinnedNow,
      category: "DEPOSIT",
      direction: .credit,
      assetSymbol: "AUD",
      amount: amount,
      isFiat: true,
      orderId: nil)
    fixture.store.appendSourceForTesting(
      CoinstashSyncSource(
        tokenStore: tokenStore,
        client: TokenRoutingExchangeClient(rowsByToken: [token: [deposit]]),
        engine: ExchangeSyncEngine(
          resolver: ExchangeInstrumentResolver(
            registry: registry, fiatInstrument: .AUD,
            existingLegInstrumentIds: { [] }),
          discovery: discovery,
          importOriginFactory: { accountId in
            ImportOrigin(
              rawDescription: "exchange:\(accountId.uuidString)",
              rawAmount: 0,
              importedAt: pinnedNow,
              importSessionId: UUID(),
              parserIdentifier: "coinstash")
          }),
        metadataResolverFactory: { _ in StubMetadataResolver([:]) }))
    return account
  }
}
