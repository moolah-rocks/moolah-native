// MoolahTests/Features/Sync/SyncedAccountStoreGlobalErrorTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SyncedAccountStore.globalError`. The banner powers
/// `CryptoSettingsView.alchemyStatusBadge`: it must surface whenever a
/// build phase produces a process-wide failure (`.missingApiKey` /
/// `.invalidApiKey`) — either of those means no account can sync, so
/// the user needs the global affordance, not a per-account caption —
/// and clear once a sync cycle runs without one. It must NOT clear on
/// apply success when every account failed in the build phase (the
/// apply pass succeeds with empty input); doing so would leave the
/// user staring at a per-row error caption with no global affordance
/// to fix the underlying problem. These tests pin that contract.
@Suite("SyncedAccountStore — globalError banner")
@MainActor
struct SyncedAccountStoreGlobalErrorTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  /// Crypto-path errors injected into the Alchemy stub must carry
  /// `provider: .alchemy` — that is exactly the shape a real failure
  /// reaches `updateGlobalError` with, because `LiveAlchemyClient` stamps
  /// every error at its client boundary (`attributingErrors(to: .alchemy)`).
  /// Injecting the *unattributed* factory value here would let a
  /// whole-`WalletSyncError`-value `switch` in the global-error dispatch
  /// pass these tests while silently failing in production; the attributed
  /// form makes the tests fail if anyone reverts the `.kind` match.
  nonisolated static let alchemyMissingApiKey = WalletSyncError(
    provider: .alchemy, kind: .missingApiKey)
  nonisolated static let alchemyInvalidApiKey = WalletSyncError(
    provider: .alchemy, kind: .invalidApiKey)

  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
  }

  private func makeStore() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let registry = GRDBInstrumentRegistryRepository(database: database)
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
    return Fixture(
      store: store, backend: backend, database: database, alchemy: alchemy)
  }

  private func seedCryptoAccount(
    in database: DatabaseQueue,
    walletAddress: String = "0x" + String(UUID().uuidString.prefix(40)),
    chain: ChainConfig = .ethereum
  ) -> Account {
    let account = Account(
      name: "Wallet \(walletAddress.suffix(4))",
      type: .crypto,
      instrument: chain.nativeInstrument,
      walletAddress: walletAddress.lowercased(),
      chainId: chain.chainId)
    _ = TestBackend.seed(accounts: [account], in: database)
    return account
  }

  @Test("Successful sync clears any prior globalError")
  func successfulSyncClearsGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    fixture.store.setGlobalError(.invalidApiKey)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == nil)
  }

  @Test(".invalidApiKey from a build phase surfaces as globalError")
  func invalidApiKeyRaisesGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(Self.alchemyInvalidApiKey), for: address)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == .invalidApiKey)
  }

  @Test(".missingApiKey from a build phase surfaces as globalError")
  func missingApiKeyRaisesGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(Self.alchemyMissingApiKey), for: address)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == .missingApiKey)
  }

  @Test(".missingApiKey wins over .invalidApiKey when both are present")
  func missingApiKeyWinsOverInvalidApiKey() async throws {
    let fixture = try makeStore()
    let invalidAccount = seedCryptoAccount(in: fixture.database)
    let missingAccount = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: invalidAccount.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: missingAccount.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let invalidAddress = try #require(invalidAccount.walletAddress)
    let missingAddress = try #require(missingAccount.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(Self.alchemyInvalidApiKey), for: invalidAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(Self.alchemyMissingApiKey), for: missingAddress)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == .missingApiKey)
  }

  @Test("Per-account network errors do not raise globalError")
  func networkErrorDoesNotRaiseGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.network(underlyingDescription: "offline")),
      for: address)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == nil)
  }

  @Test("All-success cycle after .invalidApiKey clears globalError")
  func subsequentSuccessClearsGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(Self.alchemyInvalidApiKey), for: address)

    await fixture.store.syncStaleAccounts()
    #expect(fixture.store.globalError == .invalidApiKey)

    // Now the user sets a valid key — the next cycle returns transfers
    // (or an empty list) and the banner clears.
    fixture.alchemy.setTransfersResponse(.transfers([]), for: address)
    await fixture.store.syncAccount(account)

    #expect(fixture.store.globalError == nil)
  }

  // MARK: - globalError is crypto-scoped (the banner is Alchemy-specific)

  /// Seeds an exchange account + saves its token, registering a
  /// `CoinstashSyncSource` whose stub client throws the given error.
  private func registerFailingExchangeAccount(
    in fixture: Fixture, token: String, error: ExchangeClientError
  ) throws -> Account {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    _ = TestBackend.seed(accounts: [account], in: fixture.database)
    let tokenStore = ExchangeTokenStore(synchronizable: false)
    try tokenStore.save(token: token, for: account.id)
    let registry = StubInstrumentRegistry()
    let regResolver = CountingRegistrationResolver()
    regResolver.setDefault(.success(coingecko: "id", cryptocompare: nil, binance: nil))
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: regResolver, alchemy: CountingAlchemyClientStub())
    fixture.store.appendSourceForTesting(
      CoinstashSyncSource(
        tokenStore: tokenStore,
        client: StubExchangeClient(error: error),
        engine: ExchangeSyncEngine(
          resolver: ExchangeInstrumentResolver(
            registry: registry, fiatInstrument: .AUD,
            existingLegInstrumentIds: { [] }),
          discovery: discovery),
        metadataResolverFactory: { _ in StubMetadataResolver([:]) }))
    return account
  }

  @Test("Exchange .invalidApiKey does NOT set the Alchemy globalError banner")
  func exchangeInvalidApiKeyDoesNotRaiseGlobalError() async throws {
    let fixture = try makeStore()
    let exchange = try registerFailingExchangeAccount(
      in: fixture, token: "BAD", error: .unauthorized)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: exchange.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncStaleAccounts()

    // The exchange build failed with `.invalidApiKey`, but the banner is
    // Alchemy-specific — it must stay clear. The per-account error is
    // still recorded on the row.
    #expect(fixture.store.globalError == nil)
    let state = try #require(
      try await fixture.backend.walletSyncState.load(accountId: exchange.id))
    #expect(state.lastError?.kind == .invalidApiKey)
    #expect(state.lastError?.provider == .coinstash)
  }

  @Test("Crypto .invalidApiKey still sets globalError even alongside a failing exchange")
  func cryptoStillRaisesGlobalErrorWithFailingExchange() async throws {
    let fixture = try makeStore()
    let crypto = seedCryptoAccount(in: fixture.database)
    let exchange = try registerFailingExchangeAccount(
      in: fixture, token: "BAD", error: .unauthorized)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: crypto.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: exchange.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(crypto.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(Self.alchemyInvalidApiKey), for: address)

    await fixture.store.syncStaleAccounts()

    // The crypto failure drives the (Alchemy) banner; the exchange
    // failure is scoped out.
    #expect(fixture.store.globalError == .invalidApiKey)
  }
}
