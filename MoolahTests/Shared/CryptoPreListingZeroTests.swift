import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService pre-listing zero valuation")
struct CryptoPreListingZeroTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    binanceSymbol: "ETHUSDT"
  )

  private func day(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  /// Injects a pre-built cache entry with `firstTradedOn` set, then marks the
  /// token as hydrated so `price(for:)` skips the SQL load path.
  private func injectCache(
    into service: CryptoPriceService,
    tokenId: String,
    symbol: String,
    firstTradedOn: String,
    floorPrice: Decimal
  ) async {
    var series = SortedDateSeries<Decimal>()
    if let key = DateKey.from(isoString: firstTradedOn) {
      series.upsert(floorPrice, forKey: key)
    }
    let cache = CryptoPriceCache(
      tokenId: tokenId,
      symbol: symbol,
      earliestDate: firstTradedOn,
      latestDate: firstTradedOn,
      prices: series,
      firstTradedOn: firstTradedOn
    )
    await service.injectCacheForTesting(cache)
  }

  // MARK: - Test 1: pre-listing date resolves to .knownZero

  @Test("priceLookup returns .knownZero for a date strictly before firstTradedOn")
  func preListingIsKnownZero() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    // Client fails on any request — the test must NOT reach the provider
    // for dates before the firstTradedOn floor.
    let service = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: [:], shouldFail: true)],
      database: database,
      now: { ISO8601DateFormatter().date(from: "2026-01-01") ?? Date() }
    )
    await injectCache(
      into: service, tokenId: "1:native", symbol: "ETH",
      firstTradedOn: "2024-10-01", floorPrice: dec("1000"))

    let registration = CryptoRegistration(
      instrument: ethInstrument, mapping: ethMapping, pricingStatus: .priced)
    let result = try await service.priceLookup(for: registration, on: try day("2024-09-25"))

    #expect(result == .knownZero)
  }

  // MARK: - Test 2: gap on/after the floor still throws (not silently zeroed)

  @Test("priceLookup throws for an uncached gap on or after firstTradedOn")
  func postFirstTradeGapThrows() async throws {
    // firstTradedOn = "2024-10-01"; cache is empty of prices (only floor
    // metadata is set). 2024-10-01 is on the floor; with a failing client
    // the provider is unavailable. Must throw, not return .knownZero.
    // (Using an empty price series means there is no floor fallback to mask
    // the provider failure — the token genuinely has no cached price here.)
    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: [:], shouldFail: true)],
      database: database,
      now: { ISO8601DateFormatter().date(from: "2026-01-01") ?? Date() }
    )
    // Inject cache with empty prices but firstTradedOn set. Requesting a date
    // at the floor has no cached price; with all providers failing the call
    // must propagate the provider error — not return .knownZero.
    let emptyCache = CryptoPriceCache(
      tokenId: "1:native",
      symbol: "ETH",
      earliestDate: "2024-10-01",
      latestDate: "2024-10-01",
      prices: SortedDateSeries<Decimal>(),
      firstTradedOn: "2024-10-01"
    )
    await service.injectCacheForTesting(emptyCache)

    let registration = CryptoRegistration(
      instrument: ethInstrument, mapping: ethMapping, pricingStatus: .priced)
    await #expect(throws: (any Error).self) {
      _ = try await service.priceLookup(for: registration, on: try day("2024-10-01"))
    }
  }
}
