// MoolahTests/Features/Sync/SyncedAccountStoreExchangeTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Integration test: one `SyncedAccountStore` syncs an `.exchange`
/// account through the SAME parallel-build -> sequential-apply pipeline
/// the crypto path uses, via a registered `CoinstashSyncSource` — no
/// exchange-specific store, no duplicated orchestration.
///
/// Mirrors the crypto suites' `TestBackend` fixture shape (there is no
/// shared `SyncedAccountStoreTestHarness` in this codebase — the
/// per-suite `Fixture` + `makeStore` helper is the real scaffolding).
/// The store is built first, then the exchange source is registered via
/// the test-only `appendSourceForTesting(_:)` so it can use
/// fixture-owned collaborators.
@Suite("SyncedAccountStore — exchange via shared pipeline")
@MainActor
struct SyncedAccountStoreExchangeTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
  }

  private func makeFixture() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver())
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: { accountId in
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: UUID(),
          parserIdentifier: "alchemy-wallet-sync")
      })
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow })
    return Fixture(store: store, backend: backend, database: database)
  }

  /// Seeds an `.exchange` account, saves its token, and registers a
  /// `CoinstashSyncSource` whose stub client returns one fiat deposit.
  private func makeExchangeAccount(
    in fixture: Fixture, token: String
  ) throws -> Account {
    try makeExchangeAccount(
      in: fixture, token: token,
      client: StubExchangeClient(deposit: 100),
      metadataResolver: StubMetadataResolver([:]))
  }

  /// Seeds an `.exchange` account and registers a `CoinstashSyncSource`
  /// wired with the supplied `client` and `metadataResolver`. Used by
  /// tests that need to exercise the crypto (non-fiat) resolution path.
  ///
  /// Uses `fixture.backend.grdbInstruments` — the shared profile-index
  /// registry — so instrument lookup/registration targets the correct DB
  /// (the per-profile `data.sqlite` has no `instrument` table).
  private func makeExchangeAccount(
    in fixture: Fixture,
    token: String,
    client: any ExchangeClient,
    metadataResolver: any ExchangeAssetMetadataResolving
  ) throws -> Account {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    _ = TestBackend.seed(accounts: [account], in: fixture.database)
    let tokenStore = ExchangeTokenStore(synchronizable: false)
    try tokenStore.save(token: token, for: account.id)
    // Instrument identity lives on the shared profile-index registry, not on
    // the per-profile data.sqlite. Use the backend's own registry instance so
    // crypto registrations land in the same DB the transaction reader resolves from.
    let registry = fixture.backend.grdbInstruments
    let regResolver = CountingRegistrationResolver()
    regResolver.setDefault(.success(coingecko: "id", binance: nil))
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: regResolver)
    fixture.store.appendSourceForTesting(
      CoinstashSyncSource(
        tokenStore: tokenStore,
        client: client,
        engine: ExchangeSyncEngine(
          resolver: ExchangeInstrumentResolver(
            registry: registry, fiatInstrument: .AUD,
            existingLegInstrumentIds: { [] }),
          discovery: discovery,
          importOriginFactory: { accountId in
            ImportOrigin(
              rawDescription: "exchange:\(accountId.uuidString)",
              rawAmount: 0,
              importedAt: Self.pinnedNow,
              importSessionId: UUID(),
              parserIdentifier: "coinstash")
          }),
        metadataResolverFactory: { _ in metadataResolver }))
    return account
  }

  @Test("Store syncs an exchange account through the shared pipeline")
  func storeSyncsExchangeAccountThroughSharedPipeline() async throws {
    let fixture = try makeFixture()
    let account = try makeExchangeAccount(in: fixture, token: "TOK")
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncAccount(account)

    // No per-account error recorded — the exchange build + apply landed.
    let state = try await fixture.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastError == nil)
    // The deposit row reached the DB through the shared apply pass, with
    // its provider `externalId` preserved on the leg.
    let txns = try await fixture.backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(txns.contains { txn in txn.legs.contains { $0.externalId != nil } })
  }

  /// End-to-end: a crypto OP deposit resolves to the canonical Optimism
  /// instrument id and is NOT spam-flagged.
  @Test("Store syncs a crypto OP deposit to the correct instrument id")
  func storeSyncsCryptoDepositToCorrectInstrumentId() async throws {
    let fixture = try makeFixture()
    let opTransaction = ExchangeImportedTransaction(
      externalId: "op-dep-1",
      occurredAt: Self.pinnedNow,
      category: "DEPOSIT",
      direction: .credit,
      assetSymbol: "OP",
      amount: 40167,
      isFiat: false,
      orderId: nil)
    let opMetadata = StubMetadataResolver([
      "OP": ExchangeAssetMetadata(
        symbol: "OP", name: "Optimism",
        chains: [
          ExchangeAssetChain(
            chainId: 10,
            contractAddress: "0x4200000000000000000000000000000000000042",
            decimals: 18)
        ])
    ])
    let account = try makeExchangeAccount(
      in: fixture, token: "TOK",
      client: StubExchangeClient(transactions: [opTransaction]),
      metadataResolver: opMetadata)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncAccount(account)

    // No error recorded — the crypto build + apply landed.
    let state = try await fixture.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastError == nil)

    let txns = try await fixture.backend.transactions.fetchAll(filter: TransactionFilter())
    let leg = try #require(
      txns.flatMap(\.legs).first { $0.externalId == "op-dep-1" },
      "OP deposit leg must be persisted with its externalId")
    #expect(
      leg.instrument.id == "10:0x4200000000000000000000000000000000000042",
      "leg must resolve to canonical Optimism OP instrument id")
    // Verify it is not spam-flagged: OP at its canonical address is not
    // impersonation, so the canonical-registry check passes it through.
    let regs = try await fixture.backend.grdbInstruments.allCryptoRegistrations()
    let opReg = try #require(
      regs.first { $0.instrument.id == "10:0x4200000000000000000000000000000000000042" },
      "OP instrument must be registered in the instrument registry")
    #expect(opReg.pricingStatus != .spam)
  }
}
