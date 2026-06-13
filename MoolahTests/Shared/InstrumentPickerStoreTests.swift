import Foundation
import Testing
import os

@testable import Moolah

@Suite("InstrumentPickerStore")
@MainActor
struct InstrumentPickerStoreTests {
  @Test("start() yields registered + ambient fiat for fiat-only kinds")
  func startYieldsFiatList() async throws {
    let (backend, _) = try TestBackend.create()
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistryRepository,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistryRepository,
      kinds: [.fiatCurrency]
    )
    await store.start()
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(store.results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  }

  @Test("typed query narrows to matching ISO codes")
  func typedQueryNarrows() async throws {
    let (backend, _) = try TestBackend.create()
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistryRepository,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistryRepository,
      kinds: [.fiatCurrency]
    )
    await store.start()
    store.updateQuery("usd")
    await store.waitForPendingSearch()
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(
      store.results.allSatisfy {
        $0.instrument.id.lowercased().contains("usd")
          || $0.instrument.name.localizedCaseInsensitiveContains("dollar")
      })
  }

  @Test("select of registered fiat returns the instrument without registry write")
  func selectRegisteredFiat() async throws {
    let (backend, _) = try TestBackend.create()
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistryRepository,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistryRepository,
      kinds: [.fiatCurrency]
    )
    await store.start()
    let usd = try #require(store.results.first { $0.instrument.id == "USD" })
    let picked = await store.select(usd)
    #expect(picked?.id == "USD")
    // Registry should be unchanged: no new stock/crypto rows added.
    let registered = try await backend.instrumentRegistryRepository.all()
    #expect(registered.allSatisfy { $0.kind == .fiatCurrency })
  }

  @Test("kinds: [.fiatCurrency] excludes registered stocks")
  func kindsFilterExcludesStocks() async throws {
    let (backend, _) = try TestBackend.create()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await backend.instrumentRegistryRepository.registerStock(bhp)
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistryRepository,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistryRepository,
      kinds: [.fiatCurrency]
    )
    await store.start()
    #expect(store.results.allSatisfy { $0.instrument.kind == .fiatCurrency })
    #expect(store.results.contains { $0.instrument.id == "ASX:BHP.AX" } == false)
  }

  @Test("no-service mode returns Instrument.commonFiatCodes filtered by kinds")
  func noServiceFiatList() async {
    let store = InstrumentPickerStore(kinds: [.fiatCurrency])
    await store.start()
    for code in Instrument.commonFiatCodes {
      #expect(store.results.contains { $0.instrument.id == code })
    }
  }

  @Test("no-service mode narrows by typed query")
  func noServiceTypedQuery() async throws {
    let store = InstrumentPickerStore(kinds: [.fiatCurrency])
    await store.start()
    store.updateQuery("usd")
    await store.waitForPendingSearch()
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(
      store.results.allSatisfy {
        $0.instrument.id == "USD"
          || $0.instrument.name.localizedCaseInsensitiveContains("dollar")
      })
  }

  @Test("no-service mode returns empty when kinds excludes fiat")
  func noServiceNonFiatKinds() async {
    let store = InstrumentPickerStore(kinds: [.stock])
    await store.start()
    #expect(store.results.isEmpty)
  }

  @Test("select of unregistered Yahoo stock auto-registers and returns")
  func selectStockAutoRegisters() async throws {
    let (backend, _) = try TestBackend.create()
    let stockHit = StockSearchHit(
      symbol: "AAPL", name: "Apple Inc.", exchange: "NASDAQ", quoteType: .equity)
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistryRepository,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient(hits: [stockHit])
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistryRepository,
      kinds: Set(Instrument.Kind.allCases)
    )
    store.updateQuery("AAPL")
    await store.waitForPendingSearch()
    let hit = try #require(store.results.first { $0.instrument.ticker == "AAPL" })
    #expect(hit.isRegistered == false)
    let picked = await store.select(hit)
    #expect(picked?.ticker == "AAPL")
    let registered = try await backend.instrumentRegistryRepository.all()
    #expect(registered.contains { $0.id == "NASDAQ:AAPL" })
  }

}

private struct StubStockSearchClient: StockSearchClient {
  let hits: [StockSearchHit]

  init(hits: [StockSearchHit] = []) { self.hits = hits }

  func search(query: String) async throws -> [StockSearchHit] { hits }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    .init()
  }
}
