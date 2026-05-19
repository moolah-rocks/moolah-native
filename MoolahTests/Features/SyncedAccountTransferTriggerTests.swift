import Foundation
import GRDB
import Testing

@testable import Moolah

/// Proves the crypto/exchange sync path drives transfer detection from
/// the apply pass's *genuinely-new survivors*, not a date-window scan
/// over all transactions in the window.
///
/// The record model has no negative-assertion tombstone, so a
/// dismissed/merged pair must never be re-evaluated. The only safe input
/// is the set of transactions this pass actually persisted —
/// `WalletApplyEngine.apply`'s merged-and-deduped return value, threaded
/// through `runApplyPass` → `runTransferDetection`.
///
/// Two scenarios share the harness:
///
/// - A sync pass that genuinely creates exactly one opposing exchange
///   transaction, with a pre-existing opposing leg on a *non-synced*
///   account dated inside the 3-day window, produces exactly one
///   `TransferSuggestion` for that new+existing pair.
/// - A second sync pass whose exchange client returns nothing (apply
///   persists nothing → empty survivor set) creates NO suggestion even
///   though a separate pre-existing opposing pair sits inside the
///   window. The deleted date-window behaviour would have re-suggested
///   it.
///
/// Mirrors `SyncedAccountStoreTransferDetectionTests`' exchange harness;
/// the coordinator is constructed with the current
/// `suggestions:` repository handle.
@Suite("SyncedAccountStore — detection driven by apply survivors, not a window")
@MainActor
struct SyncedAccountTransferTriggerTests {
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
    let registry = backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver(),
      alchemy: alchemy)
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

  /// Seeds one `.exchange` account, saves its token, and registers a
  /// single `CoinstashSyncSource` whose routing client returns `rows`
  /// for that token. Fiat rows (no metadata call) resolve to `.AUD`
  /// deterministically with no network.
  private func seedSyncedExchangeAccount(
    in fixture: Fixture,
    token: String,
    rows: [ExchangeImportedTransaction]
  ) throws -> Account {
    let account = Account(
      name: "Exchange Synced", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    _ = TestBackend.seed(accounts: [account], in: fixture.database)

    let tokenStore = ExchangeTokenStore(synchronizable: false)
    try tokenStore.save(token: token, for: account.id)

    let registry = fixture.backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver(),
      alchemy: CountingAlchemyClientStub())
    fixture.store.appendSourceForTesting(
      CoinstashSyncSource(
        tokenStore: tokenStore,
        client: TokenRoutingExchangeClient(rowsByToken: [token: rows]),
        engine: ExchangeSyncEngine(
          resolver: ExchangeInstrumentResolver(
            registry: registry, fiatInstrument: .AUD,
            existingLegInstrumentIds: { [] }),
          discovery: discovery),
        metadataResolverFactory: { _ in StubMetadataResolver([:]) }))
    return account
  }

  private func seedFreshSyncState(
    for account: Account, in fixture: Fixture
  ) async throws {
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
  }

  /// A single-leg cash transaction on a (non-synced) manual account
  /// dated inside the detection window.
  private func cashTx(
    account: UUID, amount: Decimal, type: TransactionType
  ) -> Transaction {
    Transaction(
      id: UUID(),
      date: Self.pinnedNow,
      legs: [
        TransactionLeg(
          accountId: account,
          instrument: .AUD,
          quantity: amount,
          type: type)
      ])
  }

  @Test("Genuinely-new sync transaction pairs with a pre-existing opposing leg")
  func newSurvivorPairsWithExistingNonSyncedLeg() async throws {
    let fixture = try makeFixture()

    // Pre-existing OUTGOING leg on a non-synced manual account, dated
    // inside the 3-day window. This is the counterpart the sync's
    // genuinely-new survivor must pair with.
    let manualAccountId = UUID()
    let existingOutgoing = cashTx(
      account: manualAccountId, amount: -250, type: .expense)
    TestBackend.seed(transactions: [existingOutgoing], in: fixture.database)

    // The sync pass genuinely creates exactly ONE opposing deposit on a
    // synced exchange account.
    let deposit = ExchangeImportedTransaction(
      externalId: "synced-deposit-1",
      occurredAt: Self.pinnedNow,
      category: "DEPOSIT",
      direction: .credit,
      assetSymbol: "AUD",
      amount: 250,
      isFiat: true,
      orderId: nil)
    let syncedAccount = try seedSyncedExchangeAccount(
      in: fixture, token: "TOK-SYNC", rows: [deposit])
    try await seedFreshSyncState(for: syncedAccount, in: fixture)
    await fixture.store.loadInitialState()

    await fixture.store.syncAccounts([syncedAccount])

    let txns = try await fixture.backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(txns.count == 2)
    let imported = try #require(
      txns.first { $0.legs.contains { $0.externalId == "synced-deposit-1" } })

    let suggestions = try await fixture.backend.transferSuggestions.fetchAll()
    #expect(suggestions.count == 1)
    let suggestion = try #require(suggestions.first)
    #expect(suggestion.transactionIds == [imported.id, existingOutgoing.id])
    #expect(suggestion.counterpart(of: imported.id) == existingOutgoing.id)
    #expect(suggestion.suggestedAt == Self.pinnedNow)
  }

  @Test("A sync that persists nothing makes no suggestion for a pre-existing window pair")
  func emptySurvivorSetDoesNotReSuggestPreExistingWindowPair() async throws {
    let fixture = try makeFixture()

    // A complete opposing pair already exists, both legs on non-synced
    // manual accounts, both dated inside the 3-day window. The deleted
    // date-window scan would have re-evaluated these and produced a
    // suggestion; the survivor-driven trigger must not.
    let manualA = UUID()
    let manualB = UUID()
    let existingOut = cashTx(account: manualA, amount: -250, type: .expense)
    let existingIn = cashTx(account: manualB, amount: 250, type: .income)
    TestBackend.seed(
      transactions: [existingOut, existingIn], in: fixture.database)

    // The sync pass genuinely creates nothing: the routing client
    // returns no rows for this account's token, so the apply pass's
    // survivor set is empty.
    let syncedAccount = try seedSyncedExchangeAccount(
      in: fixture, token: "TOK-EMPTY", rows: [])
    try await seedFreshSyncState(for: syncedAccount, in: fixture)
    await fixture.store.loadInitialState()

    await fixture.store.syncAccounts([syncedAccount])

    // The two pre-existing transactions are untouched and NO suggestion
    // was created — detection never saw them because they are not part
    // of this pass's genuinely-new survivor set.
    let txns = try await fixture.backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(txns.count == 2)
    let suggestions = try await fixture.backend.transferSuggestions.fetchAll()
    #expect(suggestions.isEmpty)
  }
}
