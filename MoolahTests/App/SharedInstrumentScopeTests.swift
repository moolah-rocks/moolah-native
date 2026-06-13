// MoolahTests/App/SharedInstrumentScopeTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `SharedInstrumentScope` constructs a passive holder of the
/// shared registry and price-cache / search / discovery services and
/// exposes them via its public surface.
@MainActor
@Suite("SharedInstrumentScope holder")
struct SharedInstrumentScopeTests {

  @Test("holds the registry and exposes shared price-cache through the same DB")
  func scopeHoldsSharedRegistryWiredToProfileIndexDatabase() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    let scope = makeScope(database: queue, registry: registry)

    // Registry round-trip: register an instrument via the holder's
    // registry, observe the row in the same shared DB.
    try await scope.instrumentRegistry.registerCrypto(
      Instrument.crypto(
        chainId: 1,
        contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        symbol: "USDC",
        name: "USD Coin",
        decimals: 6),
      mapping: CryptoProviderMapping(
        instrumentId:
          "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        coingeckoId: "usd-coin",
        cryptocompareSymbol: "USDC",
        binanceSymbol: nil))

    let stored = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM instrument") ?? 0
    }
    #expect(stored == 1)
  }

  @Test("exposes price-cache and discovery services as the same instances handed in")
  func scopeExposesInjectedServicesByIdentity() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)
    let cryptoPriceService = CryptoPriceService(
      clients: [],
      database: queue,
      resolutionClient: FixedTokenResolutionClient())
    let stockPriceService = StockPriceService(
      client: FixedStockPriceClient(), database: queue)
    let exchangeRateService = ExchangeRateService(
      client: FixedRateClient(), database: queue)
    let searchService = InstrumentSearchService(
      registry: registry,
      catalog: nil,
      resolutionClient: FixedTokenResolutionClient(),
      stockSearchClient: NoOpStockSearchClient())
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver())

    let scope = SharedInstrumentScope(
      instrumentRegistry: registry,
      cryptoPriceService: cryptoPriceService,
      stockPriceService: stockPriceService,
      exchangeRateService: exchangeRateService,
      instrumentSearchService: searchService,
      cryptoTokenDiscovery: discovery)

    #expect(scope.cryptoPriceService === cryptoPriceService)
    #expect(scope.stockPriceService === stockPriceService)
    #expect(scope.exchangeRateService === exchangeRateService)
    #expect(scope.cryptoTokenDiscovery === discovery)
    // `instrumentRegistry` and `searchService` are protocol / value
    // types — equality by content not reference.
  }

  // MARK: - Helpers

  @MainActor
  private func makeScope(
    database: any DatabaseWriter,
    registry: any InstrumentRegistryRepository
  ) -> SharedInstrumentScope {
    SharedInstrumentScope(
      instrumentRegistry: registry,
      cryptoPriceService: CryptoPriceService(
        clients: [],
        database: database,
        resolutionClient: FixedTokenResolutionClient()),
      stockPriceService: StockPriceService(
        client: FixedStockPriceClient(), database: database),
      exchangeRateService: ExchangeRateService(
        client: FixedRateClient(), database: database),
      instrumentSearchService: InstrumentSearchService(
        registry: registry,
        catalog: nil,
        resolutionClient: FixedTokenResolutionClient(),
        stockSearchClient: NoOpStockSearchClient()),
      cryptoTokenDiscovery: CryptoTokenDiscoveryService(
        registry: registry,
        resolver: CountingRegistrationResolver()))
  }
}

/// Minimal `StockSearchClient` stub for unit tests that only need the
/// `SharedInstrumentScope`'s wiring to compile and execute. Returns no
/// results for every query.
private struct NoOpStockSearchClient: StockSearchClient {
  func search(query: String) async throws -> [StockSearchHit] { [] }
}
