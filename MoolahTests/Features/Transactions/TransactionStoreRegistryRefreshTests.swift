import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cross-database refresh coverage for the reactive `TransactionStore`.
///
/// Per-profile list observations do not track the `instrument` table:
/// instrument identity lives in the shared registry, and the repository
/// resolves it once per fetch via the shared `instrumentMap()` snapshot
/// rather than joining `InstrumentRow` into the per-profile observation
/// region. An instrument-METADATA edit (rename, ticker, pricing-status)
/// applied to the shared registry therefore does not re-fire the
/// per-profile observation on its own, which would leave an already-open
/// transaction list rendering stale instrument metadata.
///
/// These tests pin that the store additionally consumes the shared
/// registry's `observeChanges()` stream and, on each tick, re-runs its
/// fetch + recompute path so the open list live-refreshes across the
/// DB boundary.
@Suite("TransactionStore registry refresh", .serialized)
@MainActor
struct TransactionStoreRegistryRefreshTests {

  private let accountId = UUID()
  private let wbtcAddress = "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"

  /// A WBTC crypto instrument with the given display name.
  private func wbtc(named name: String) -> Instrument {
    Instrument.crypto(
      chainId: 1, contractAddress: wbtcAddress, symbol: "WBTC",
      name: name, decimals: 8)
  }

  /// Registers `crypto` (upsert) with a CoinGecko-only mapping.
  private func register(
    _ crypto: Instrument, in registry: GRDBInstrumentRegistryRepository
  ) async throws {
    try await registry.registerCrypto(
      crypto,
      mapping: CryptoProviderMapping(
        instrumentId: crypto.id, coingeckoId: "wrapped-bitcoin",
        cryptocompareSymbol: nil, binanceSymbol: nil))
  }

  /// A two-leg crypto trade (WBTC bought with the test fiat).
  private func trade(crypto: Instrument) -> Transaction {
    Transaction(
      date: Date(),
      payee: "Bought WBTC",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: crypto, quantity: 5, type: .trade),
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -1_000, type: .trade),
      ])
  }

  private func makeStore(
    _ backend: CloudKitBackend, _ registry: GRDBInstrumentRegistryRepository
  ) -> TransactionStore {
    TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      instrumentChanges: registry)
  }

  /// The rendered crypto leg's instrument name, or nil.
  private func cryptoLegName(
    _ store: TransactionStore, id: String
  ) -> String? {
    store.transactions.first?.transaction.legs
      .first { $0.instrument.id == id }?.instrument.name
  }

  @Test("instrument rename in the shared registry refreshes the open list")
  func instrumentRenameRefreshesOpenList() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let (backend, _) = try TestBackend.create(sharedRegistry: registry)
    let crypto = wbtc(named: "Wrapped Bitcoin")
    try await register(crypto, in: registry)
    _ = try await backend.transactions.create(trade(crypto: crypto))

    let store = makeStore(backend, registry)
    await store.load(filter: TransactionFilter(accountId: accountId))
    await expectEventually("store sees the seeded crypto transaction") {
      store.transactions.count == 1
        && self.cryptoLegName(store, id: crypto.id) == "Wrapped Bitcoin"
    }

    // Rename in the SHARED registry. No per-profile GRDB write happens,
    // so the data-change observation does NOT re-fire — only the
    // registry's `observeChanges()` stream does.
    try await register(wbtc(named: "Renamed WBTC"), in: registry)

    try await store.waitForNextEmission(
      matching: { self.cryptoLegName($0, id: crypto.id) == "Renamed WBTC" },
      description: "registry rename live-refreshes the open list")

    store.stopObserving()
  }

  @Test("registry change after stopObserving does not refresh the store")
  func registryChangeAfterStopDoesNotRefresh() async throws {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let (backend, _) = try TestBackend.create(sharedRegistry: registry)
    let crypto = wbtc(named: "Wrapped Bitcoin")
    try await register(crypto, in: registry)
    _ = try await backend.transactions.create(trade(crypto: crypto))

    let store = makeStore(backend, registry)
    await store.load(filter: TransactionFilter(accountId: accountId))
    try await store.waitForNextEmission(
      matching: { $0.transactions.count == 1 },
      description: "store sees the seeded crypto transaction")
    await store.drainPendingEmissions()
    store.stopObserving()
    await store.awaitObservationTermination()

    try await register(wbtc(named: "Renamed after stop"), in: registry)

    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }
}
