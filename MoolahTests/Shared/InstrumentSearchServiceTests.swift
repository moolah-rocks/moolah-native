import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentSearchService")
@MainActor
struct InstrumentSearchServiceTests {
  func makeSubject(
    registered: [Instrument] = [],
    cryptoRegistrations: [CryptoRegistration] = [],
    catalogEntries: [CatalogEntry] = [],
    stockHits: [StockSearchHit] = [],
    stockSearchThrows: Bool = false,
    resolvedRegistration: CryptoRegistration? = nil
  ) -> InstrumentSearchService {
    let registry = StubInstrumentRegistry(
      instruments: registered, cryptoRegistrations: cryptoRegistrations)
    let catalog = StubCatalog(entries: catalogEntries)
    let stock = StubStockSearchClient(hits: stockHits, shouldThrow: stockSearchThrows)
    let resolver = StubTokenResolutionClient(resolved: resolvedRegistration)
    return InstrumentSearchService(
      registry: registry,
      catalog: catalog,
      resolutionClient: resolver,
      stockSearchClient: stock
    )
  }

  @Test("fiat prefix match on ISO code")
  func fiatPrefixMatch() async throws {
    let service = makeSubject()
    let results = await service.search(query: "usd")
    #expect(results.contains { $0.instrument.id == "USD" })
    #expect(results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  }

  @Test("fiat substring match on localized name")
  func fiatNameMatch() async throws {
    let service = makeSubject()
    let results = await service.search(query: "dollar")
    let ids = results.map(\.instrument.id)
    #expect(ids.contains("USD") || ids.contains("AUD"))
  }

  @Test("crypto results loaded from catalog with platform binding")
  func cryptoResultsCarryCatalogPlatform() async throws {
    let entry = CatalogEntry(
      coingeckoId: "uniswap",
      symbol: "UNI",
      name: "Uniswap",
      platforms: [
        PlatformBinding(
          slug: "ethereum",
          chainId: 1,
          contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
        )
      ]
    )
    let service = makeSubject(catalogEntries: [entry])
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let hit = try #require(results.first)
    #expect(hit.instrument.kind == .cryptoToken)
    #expect(hit.instrument.chainId == 1)
    #expect(hit.instrument.contractAddress == "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    #expect(hit.instrument.ticker == "UNI")
    #expect(hit.requiresResolution == true)
    #expect(hit.cryptoMapping == nil)
    #expect(hit.isRegistered == false)
  }

  @Test("crypto results for platformless entries fall back to native id")
  func cryptoNativeEntryMaps() async throws {
    let entry = CatalogEntry(
      coingeckoId: "bitcoin",
      symbol: "BTC",
      name: "Bitcoin",
      platforms: []
    )
    let service = makeSubject(catalogEntries: [entry])
    let results = await service.search(query: "btc", kinds: [.cryptoToken])
    let hit = try #require(results.first)
    #expect(hit.instrument.kind == .cryptoToken)
    #expect(hit.instrument.contractAddress == nil)
    #expect(hit.instrument.ticker == "BTC")
    #expect(hit.requiresResolution == true)
  }

  @Test("registered crypto overrides catalog hit and carries mapping")
  func registeredCryptoOverridesCatalogResult() async throws {
    let registeredInstrument = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
      symbol: "UNI",
      name: "Uniswap",
      decimals: 18
    )
    let mapping = CryptoProviderMapping(
      instrumentId: registeredInstrument.id,
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT"
    )
    let registration = CryptoRegistration(
      instrument: registeredInstrument, mapping: mapping)
    let entry = CatalogEntry(
      coingeckoId: "uniswap",
      symbol: "UNI",
      name: "Uniswap",
      platforms: [
        PlatformBinding(
          slug: "ethereum",
          chainId: 1,
          contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
        )
      ]
    )
    let service = makeSubject(
      registered: [registeredInstrument],
      cryptoRegistrations: [registration],
      catalogEntries: [entry]
    )
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let matching = results.filter { $0.instrument.id == registeredInstrument.id }
    #expect(matching.count == 1)
    let hit = try #require(matching.first)
    #expect(hit.isRegistered == true)
    #expect(hit.requiresResolution == false)
    #expect(hit.cryptoMapping?.coingeckoId == "uniswap")
  }

  @Test("crypto in registered but without a mapping is treated as unregistered")
  func cryptoInRegisteredButNoMappingTreatedAsUnregistered() async throws {
    // A crypto Instrument can exist in the registry without a mapping when
    // CSV import landed it before the picker had a chance to resolve(). On
    // the catalog path that case must surface as `isRegistered: false,
    // requiresResolution: true` — the picker will then run resolve() and
    // promote it to a fully registered row. Marking it `isRegistered:
    // true` while still asking for resolution is a contradictory state.
    let preMappingInst = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xfoo",
      symbol: "FOO",
      name: "Foo Token",
      decimals: 18
    )
    let entry = CatalogEntry(
      coingeckoId: "foo",
      symbol: "FOO",
      name: "Foo Token",
      platforms: [
        PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xfoo")
      ]
    )
    // A query that matches the catalog entry (the stub catalog returns all
    // its entries regardless of query) but does NOT match the registered
    // Instrument's id, ticker, or name — so `registeredMatches` skips it
    // and the catalog branch's result survives the merge.
    let service = makeSubject(
      registered: [preMappingInst],
      cryptoRegistrations: [],
      catalogEntries: [entry]
    )
    let results = await service.search(query: "abc", kinds: [.cryptoToken])
    let foo = try #require(results.first { $0.instrument.id == "1:0xfoo" })
    #expect(foo.isRegistered == false)
    #expect(foo.requiresResolution == true)
    #expect(foo.cryptoMapping == nil)
  }

  @Test("nil catalog returns no crypto results")
  func nilCatalogYieldsEmptyCrypto() async {
    let registry = StubInstrumentRegistry()
    let service = InstrumentSearchService(
      registry: registry,
      catalog: nil,
      resolutionClient: StubTokenResolutionClient(),
      stockSearchClient: StubStockSearchClient()
    )
    let results = await service.search(query: "btc", kinds: [.cryptoToken])
    #expect(results.isEmpty)
  }

  @Test("stock results loaded from search client with quoteType-derived ids")
  func stockResultsAreLoadedFromSearchClient() async throws {
    let hits = [
      StockSearchHit(
        symbol: "AAPL", name: "Apple Inc.", exchange: "NASDAQ", quoteType: .equity),
      StockSearchHit(
        symbol: "MSFT", name: "Microsoft Corp.", exchange: "NASDAQ", quoteType: .equity),
    ]
    let service = makeSubject(stockHits: hits)
    let results = await service.search(query: "apple", kinds: [.stock])
    let aapl = try #require(results.first { $0.instrument.ticker == "AAPL" })
    #expect(aapl.instrument.id == "NASDAQ:AAPL")
    #expect(aapl.instrument.kind == .stock)
    #expect(aapl.instrument.name == "Apple Inc.")
    #expect(aapl.requiresResolution == true)
    #expect(aapl.isRegistered == false)
  }

  @Test("registered stock overrides Yahoo hit")
  func registeredStockOverridesSearchHit() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP Group")
    let hit = StockSearchHit(
      symbol: "BHP.AX", name: "BHP Group", exchange: "ASX", quoteType: .equity)
    let service = makeSubject(registered: [bhp], stockHits: [hit])
    let results = await service.search(query: "bhp", kinds: [.stock])
    let matching = results.filter { $0.instrument.id == "ASX:BHP.AX" }
    #expect(matching.count == 1)
    #expect(matching.first?.isRegistered == true)
    #expect(matching.first?.requiresResolution == false)
  }

  @Test("stock search throw is absorbed; other kinds still return")
  func stockSearchThrowAbsorbed() async throws {
    let service = makeSubject(stockSearchThrows: true)
    let results = await service.search(query: "usd")
    #expect(results.contains { $0.instrument.id == "USD" })
  }

  @Test("empty query returns the registered set")
  func emptyQueryReturnsRegistered() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let service = makeSubject(registered: [bhp])
    let results = await service.search(query: "")
    #expect(results.contains { $0.instrument.id == "ASX:BHP.AX" })
    #expect(results.allSatisfy { $0.isRegistered })
  }

  @Test("registered instruments ranked first")
  func registeredRankFirst() async throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let extraHit = StockSearchHit(
      symbol: "BHP.NS", name: "BHP", exchange: "NSE", quoteType: .equity)
    let service = makeSubject(registered: [bhp], stockHits: [extraHit])
    let results = await service.search(query: "BHP", kinds: [.stock])
    let bhpResult = try #require(results.first { $0.instrument.id == "ASX:BHP.AX" })
    #expect(bhpResult.isRegistered == true)
    let registeredIdx = try #require(
      results.firstIndex { $0.instrument.id == "ASX:BHP.AX" })
    let providerIdx =
      results.firstIndex { $0.instrument.kind == .stock && !$0.isRegistered } ?? Int.max
    #expect(registeredIdx < providerIdx)
  }

}

// MARK: - Ranking

extension InstrumentSearchServiceTests {
  @Test("exact currency code match ranks first")
  func exactCurrencyCodeRanksFirst() async throws {
    // A crypto hit that also matches "usd" by name must not displace the
    // exact ISO-code match: typing "USD" puts US Dollar first.
    let usdc = CatalogEntry(
      coingeckoId: "usd-coin",
      symbol: "USDC",
      name: "USD Coin",
      platforms: [
        PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xusdc")
      ]
    )
    let service = makeSubject(catalogEntries: [usdc])
    let results = await service.search(query: "usd", kinds: [.fiatCurrency, .cryptoToken])
    let first = try #require(results.first)
    #expect(first.instrument.id == "USD")
    #expect(first.instrument.kind == .fiatCurrency)
  }

  @Test("currency results rank before crypto tokens")
  func currencyResultsRankBeforeCrypto() async throws {
    // "dollar" matches several fiat currencies by localized name and the
    // crypto entry by name; every currency must precede every crypto token.
    let dollarCoin = CatalogEntry(
      coingeckoId: "dollar-coin",
      symbol: "DLR",
      name: "Dollar Coin",
      platforms: []
    )
    let service = makeSubject(catalogEntries: [dollarCoin])
    let results = await service.search(
      query: "dollar", kinds: [.fiatCurrency, .cryptoToken])
    let lastFiat = results.lastIndex { $0.instrument.kind == .fiatCurrency } ?? -1
    let firstCrypto = results.firstIndex { $0.instrument.kind == .cryptoToken } ?? Int.max
    #expect(lastFiat < firstCrypto)
  }

  @Test("exact ticker outranks a ticker-prefix match")
  func exactTickerOutranksPrefix() async throws {
    let uni = cryptoEntry(symbol: "UNI", name: "Uniswap", address: "0xaaa")
    let unibright = cryptoEntry(symbol: "UNIB", name: "Unibright", address: "0xbbb")
    let service = makeSubject(catalogEntries: [unibright, uni])
    let results = await service.search(query: "uni", kinds: [.cryptoToken])
    let exactIdx = try #require(results.firstIndex { $0.instrument.ticker == "UNI" })
    let prefixIdx = try #require(results.firstIndex { $0.instrument.ticker == "UNIB" })
    #expect(exactIdx < prefixIdx)
  }

  @Test("ticker prefix outranks a name word-prefix match")
  func tickerPrefixOutranksNamePrefix() async throws {
    // "comp" prefixes the COMP ticker (tier 2) but only word-prefixes the
    // "Cosmos" name (tier 3); the ticker match must lead.
    let comp = cryptoEntry(symbol: "COMP", name: "Compound", address: "0xaaa")
    let cosmos = cryptoEntry(symbol: "ATOM", name: "Cosmos Network", address: "0xbbb")
    let service = makeSubject(catalogEntries: [cosmos, comp])
    let results = await service.search(query: "co", kinds: [.cryptoToken])
    let tickerIdx = try #require(results.firstIndex { $0.instrument.ticker == "COMP" })
    let nameIdx = try #require(results.firstIndex { $0.instrument.ticker == "ATOM" })
    #expect(tickerIdx < nameIdx)
  }

  @Test("name word-prefix outranks a mid-word substring match")
  func nameWordPrefixOutranksSubstring() async throws {
    // "eth" word-prefixes "Ethereal" (tier 3) but only appears mid-word in
    // "Tether" (tier 4); neither ticker matches, so the word-prefix wins.
    let ethereal = cryptoEntry(symbol: "ETL", name: "Ethereal", address: "0xaaa")
    let tether = cryptoEntry(symbol: "USDT", name: "Tether", address: "0xbbb")
    let service = makeSubject(catalogEntries: [tether, ethereal])
    let results = await service.search(query: "eth", kinds: [.cryptoToken])
    let wordPrefixIdx = try #require(results.firstIndex { $0.instrument.ticker == "ETL" })
    let substringIdx = try #require(results.firstIndex { $0.instrument.ticker == "USDT" })
    #expect(wordPrefixIdx < substringIdx)
  }

  private func cryptoEntry(
    symbol: String, name: String, address: String
  ) -> CatalogEntry {
    CatalogEntry(
      coingeckoId: symbol.lowercased(),
      symbol: symbol,
      name: name,
      platforms: [
        PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: address)
      ]
    )
  }
}

// MARK: - Stubs

private struct StubCatalog: CoinGeckoCatalog {
  let entries: [CatalogEntry]

  init(entries: [CatalogEntry] = []) { self.entries = entries }

  func search(query: String, limit: Int) async -> [CatalogEntry] {
    Array(entries.prefix(limit))
  }
  func refreshIfStale() async {}
}

private struct StubStockSearchClient: StockSearchClient {
  let hits: [StockSearchHit]
  let shouldThrow: Bool

  init(hits: [StockSearchHit] = [], shouldThrow: Bool = false) {
    self.hits = hits
    self.shouldThrow = shouldThrow
  }

  func search(query: String) async throws -> [StockSearchHit] {
    if shouldThrow { throw URLError(.cannotConnectToHost) }
    return hits
  }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  let resolved: CryptoRegistration?

  init(resolved: CryptoRegistration? = nil) { self.resolved = resolved }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    guard let resolved else { return TokenResolutionResult() }
    return TokenResolutionResult(
      coingeckoId: resolved.mapping.coingeckoId,
      cryptocompareSymbol: resolved.mapping.cryptocompareSymbol,
      binanceSymbol: resolved.mapping.binanceSymbol,
      resolvedName: resolved.instrument.name,
      resolvedSymbol: resolved.instrument.ticker,
      resolvedDecimals: resolved.instrument.decimals
    )
  }
}
