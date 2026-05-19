// MoolahTests/Features/Sync/SyncedAccountStoreTransferDetectionTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Integration test: a `SyncedAccountStore` sync that imports an
/// opposing same-instrument pair across two exchange accounts runs the
/// fuzzy transfer-detection pass after the apply + state-refresh, so
/// a single `TransferSuggestion` record is stored in the repository for
/// the detected pair (no per-row denormalised annotation).
///
/// Two scenarios share the harness:
///
/// - Different `externalId`s on the opposing legs: `CrossAccountTransferMerger`
///   (Extension B) does not collapse them during apply, so both survive
///   as single-leg cash transactions and the detector pairs them.
/// - Same `externalId` on the opposing legs: Extension B collapses them
///   into one merged two-cash-leg transaction during the apply pass; its
///   `transferDetectionValueLeg` is `nil`, so the detector structurally
///   skips it and no suggestion record is created.
///
/// Mirrors the crypto/exchange suites' `TestBackend` fixture shape — the
/// per-suite `Fixture` + `makeFixture` helper is the real scaffolding;
/// there is no shared harness type in this codebase.
@Suite("SyncedAccountStore — transfer detection after sync")
@MainActor
struct SyncedAccountStoreTransferDetectionTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
  }

  /// `ExchangeClient` that routes a scripted row list per account token,
  /// so one registered `CoinstashSyncSource` can drive two exchange
  /// accounts with independently controlled `externalId`s through the
  /// real build → apply → detection pipeline. `StubExchangeClient`
  /// ignores the token, so the per-account split needs this routing
  /// double.
  private struct TokenRoutingExchangeClient: ExchangeClient, Sendable {
    let rowsByToken: [String: [ExchangeImportedTransaction]]

    func fetchTransactions(
      token: String
    ) async throws -> [ExchangeImportedTransaction] {
      rowsByToken[token] ?? []
    }
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
      transactions: backend.transactions,
      clock: { Self.pinnedNow })
    return Fixture(store: store, backend: backend, database: database)
  }

  /// Seeds two `.exchange` accounts, saves their tokens, and registers a
  /// single `CoinstashSyncSource` whose routing client returns the
  /// supplied rows per token. Both rows are fiat (no metadata call) so
  /// they resolve to the same `.AUD` instrument deterministically with
  /// no network.
  private func seedOpposingExchangeAccounts(
    in fixture: Fixture,
    rowA: ExchangeImportedTransaction,
    rowB: ExchangeImportedTransaction
  ) throws -> (Account, Account) {
    let accountA = Account(
      name: "Exchange A", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    let accountB = Account(
      name: "Exchange B", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    _ = TestBackend.seed(accounts: [accountA, accountB], in: fixture.database)

    let tokenStore = ExchangeTokenStore(synchronizable: false)
    try tokenStore.save(token: "TOK-A", for: accountA.id)
    try tokenStore.save(token: "TOK-B", for: accountB.id)

    let registry = fixture.backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver(),
      alchemy: CountingAlchemyClientStub())
    fixture.store.appendSourceForTesting(
      CoinstashSyncSource(
        tokenStore: tokenStore,
        client: TokenRoutingExchangeClient(rowsByToken: [
          "TOK-A": [rowA],
          "TOK-B": [rowB],
        ]),
        engine: ExchangeSyncEngine(
          resolver: ExchangeInstrumentResolver(
            registry: registry, fiatInstrument: .AUD,
            existingLegInstrumentIds: { [] }),
          discovery: discovery),
        metadataResolverFactory: { _ in StubMetadataResolver([:]) }))
    return (accountA, accountB)
  }

  private func seedFreshSyncState(
    for accounts: [Account], in fixture: Fixture
  ) async throws {
    for account in accounts {
      try await fixture.backend.walletSyncState.save(
        WalletSyncState(
          id: account.id, lastSyncedBlockNumber: 0,
          lastSyncedAt: .distantPast, lastError: nil))
    }
  }

  @Test("Different-externalId opposing exchange pair both get a suggestion")
  func differentExternalIdPairGetsSuggestion() async throws {
    let fixture = try makeFixture()
    // Account A withdraws 250 AUD; account B deposits 250 AUD. Opposing
    // signs, equal magnitude, same fiat instrument. Different
    // `externalId`s so Extension B does NOT merge them in the apply pass.
    let withdraw = ExchangeImportedTransaction(
      externalId: "a-withdraw-1",
      occurredAt: Self.pinnedNow,
      category: "WITHDRAW",
      direction: .debit,
      assetSymbol: "AUD",
      amount: 250,
      isFiat: true,
      orderId: nil)
    let deposit = ExchangeImportedTransaction(
      externalId: "b-deposit-1",
      occurredAt: Self.pinnedNow,
      category: "DEPOSIT",
      direction: .credit,
      assetSymbol: "AUD",
      amount: 250,
      isFiat: true,
      orderId: nil)
    let (accountA, accountB) = try seedOpposingExchangeAccounts(
      in: fixture, rowA: withdraw, rowB: deposit)
    try await seedFreshSyncState(for: [accountA, accountB], in: fixture)
    await fixture.store.loadInitialState()

    await fixture.store.syncAccounts([accountA, accountB])

    let txns = try await fixture.backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(txns.count == 2)
    let txnA = try #require(
      txns.first { $0.legs.contains { $0.externalId == "a-withdraw-1" } })
    let txnB = try #require(
      txns.first { $0.legs.contains { $0.externalId == "b-deposit-1" } })

    let suggestions = try await fixture.backend.transferSuggestions.fetchAll()
    #expect(suggestions.count == 1)
    let suggestion = try #require(suggestions.first)
    #expect(suggestion.transactionIds == [txnA.id, txnB.id])
    #expect(suggestion.counterpart(of: txnA.id) == txnB.id)
    #expect(suggestion.suggestedAt == Self.pinnedNow)
  }

  /// Drives a sync that imports an opposing pair sharing one
  /// `externalId` across two exchange accounts and returns every
  /// persisted transaction plus the backend for follow-on repository
  /// assertions. Identical `externalId` on the opposing legs makes
  /// Extension B's same-`externalId` pair predicate fire during the
  /// apply pass. Shared by the apply-collapse and no-suggestion tests so
  /// both observe the same single sync run shape.
  private func syncSameExternalIdOpposingPair() async throws -> ([Transaction], CloudKitBackend) {
    let fixture = try makeFixture()
    let withdraw = ExchangeImportedTransaction(
      externalId: "shared-xfer-1",
      occurredAt: Self.pinnedNow,
      category: "WITHDRAW",
      direction: .debit,
      assetSymbol: "AUD",
      amount: 250,
      isFiat: true,
      orderId: nil)
    let deposit = ExchangeImportedTransaction(
      externalId: "shared-xfer-1",
      occurredAt: Self.pinnedNow,
      category: "DEPOSIT",
      direction: .credit,
      assetSymbol: "AUD",
      amount: 250,
      isFiat: true,
      orderId: nil)
    let (accountA, accountB) = try seedOpposingExchangeAccounts(
      in: fixture, rowA: withdraw, rowB: deposit)
    try await seedFreshSyncState(for: [accountA, accountB], in: fixture)
    await fixture.store.loadInitialState()

    await fixture.store.syncAccounts([accountA, accountB])

    let txns = try await fixture.backend.transactions.fetchAll(
      filter: TransactionFilter())
    return (txns, fixture.backend)
  }

  @Test("Apply pass collapses the same-externalId opposing pair into one transaction")
  func sameExternalIdPairIsMergedByApply() async throws {
    let (txns, _) = try await syncSameExternalIdOpposingPair()

    #expect(txns.count == 1)
    let merged = try #require(txns.first)
    #expect(merged.legs.count == 2)
    // Two value legs in the same instrument → no single value leg, so
    // the detector structurally skips this merged transaction.
    #expect(merged.transferDetectionValueLeg == nil)
  }

  @Test("Apply-merged same-externalId transaction carries no transfer suggestion")
  func mergedSameExternalIdTransactionHasNoSuggestion() async throws {
    let (_, backend) = try await syncSameExternalIdOpposingPair()

    #expect(try await backend.transferSuggestions.fetchAll().isEmpty)
  }
}
