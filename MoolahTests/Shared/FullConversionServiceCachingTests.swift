import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the per-(from, to, day) memoisation on `FullConversionService`.
///
/// Background: issue #868 documented a ~1400-call burst of identical
/// `convert(_:from:to:on:)` calls within one second at cold app launch.
/// `FullConversionService` is an actor — every call serialises through
/// the executor and emits two `os_log` lines. Memoising the unit rate
/// per `(source.id, target.id, calendar-day)` collapses N identical
/// calls in a recompute cycle to one underlying lookup.
@Suite("FullConversionService caching")
struct FullConversionServiceCachingTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let usd = Instrument.USD
  private let aud = Instrument.AUD
  private let eur = Instrument.fiat(code: "EUR")

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private struct Bundle {
    let service: FullConversionService
  }

  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    registrations: [CryptoRegistration] = []
  ) throws -> Bundle {
    let database = try ProfileIndexDatabase.openInMemory()
    // Pin to UTC — `futureDatesShareTodaysCacheEntry` and the cache-key
    // assertions below assume the cap resolves "yesterday" against the
    // same UTC calendar the fixtures use to derive their date keys.
    let utc = try #require(TimeZone(identifier: "UTC"))
    let registrationsById = Dictionary(
      uniqueKeysWithValues: registrations.map { ($0.id, $0) })
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: cryptoPrices)],
      database: database,
      metadataLookup: { registrationsById[$0] },
      timeZone: utc
    )
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: exchangeRates),
      database: database,
      timeZone: utc
    )
    let stockService = StockPriceService(
      client: FixedStockPriceClient(), database: database, timeZone: utc)
    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService
    )
    return Bundle(service: service)
  }

  // MARK: - Fiat memoisation

  /// Four identical fiat calls must populate exactly one cache entry —
  /// the symptom in issue #868 was N redundant identical lookups in a
  /// recompute burst.
  @Test
  func repeatedIdenticalFiatConvertsPopulateOneCacheEntry() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5385")]]
    )

    for _ in 0..<4 {
      let result = try await bundle.service.convert(
        dec("100"), from: usd, to: aud, on: day)
      #expect(result == dec("100") * dec("1.5385"))
    }

    #expect(await bundle.service.cachedRateCountForTesting == 1)
  }

  /// Different `(from, to)` pairs on the same day are separate entries.
  @Test
  func distinctInstrumentPairsOnSameDayUseSeparateEntries() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5385"), "EUR": dec("0.92")]]
    )

    _ = try await bundle.service.convert(dec("1"), from: usd, to: aud, on: day)
    _ = try await bundle.service.convert(dec("1"), from: usd, to: eur, on: day)

    #expect(await bundle.service.cachedRateCountForTesting == 2)
  }

  /// Same `(from, to)` on distinct calendar days are separate entries.
  @Test
  func distinctDaysUseSeparateEntries() async throws {
    let bundle = try makeService(
      exchangeRates: [
        "2025-06-15": ["AUD": dec("1.5385")],
        "2025-06-16": ["AUD": dec("1.5400")],
      ]
    )

    _ = try await bundle.service.convert(
      dec("1"), from: usd, to: aud, on: try date("2025-06-15"))
    _ = try await bundle.service.convert(
      dec("1"), from: usd, to: aud, on: try date("2025-06-16"))

    #expect(await bundle.service.cachedRateCountForTesting == 2)
  }

  /// Different times within the same UTC calendar day collapse to one
  /// entry — the cache key buckets by UTC day so that recompute cycles
  /// fired at arbitrary intra-day timestamps don't multiply entries.
  /// UTC bucketing matches the underlying price services' day key.
  @Test
  func differentTimesOnSameDayShareOneEntry() async throws {
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5385")]]
    )
    let utc = try #require(TimeZone(identifier: "UTC"))
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = utc
    let morning = try #require(
      utcCalendar.date(
        from: DateComponents(timeZone: utc, year: 2025, month: 6, day: 15, hour: 9))
    )
    let evening = try #require(
      utcCalendar.date(
        from: DateComponents(timeZone: utc, year: 2025, month: 6, day: 15, hour: 21))
    )

    _ = try await bundle.service.convert(dec("1"), from: usd, to: aud, on: morning)
    _ = try await bundle.service.convert(dec("1"), from: usd, to: aud, on: evening)

    #expect(await bundle.service.cachedRateCountForTesting == 1)
  }

  /// Same-instrument identity short-circuit must NOT populate the cache:
  /// it returns `quantity` unchanged with no provider work.
  @Test
  func sameInstrumentConvertDoesNotPopulateCache() async throws {
    let bundle = try makeService()
    let result = try await bundle.service.convert(
      dec("100"), from: usd, to: usd, on: try date("2025-06-15"))
    #expect(result == dec("100"))
    #expect(await bundle.service.cachedRateCountForTesting == 0)
  }

  // MARK: - Future-date clamping interacts with the day bucket

  /// Future dates clamp to "today" before the cache lookup, so two
  /// distinct future timestamps land on the same cache entry. This is
  /// the cold-launch case where forecast / scheduled transactions feed
  /// future dates into convert calls.
  @Test
  func futureDatesShareTodaysCacheEntry() async throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    // Use UTC explicitly — both the memo bucket and `cappedToYesterday`
    // in the underlying services key off UTC days, so the fixture date
    // must agree by construction rather than depend on the host
    // timezone matching UTC at the moment the test runs.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let today = calendar.startOfDay(for: Date())
    // Yesterday matches `cappedToYesterday`'s selection when the
    // service receives a (future, clamped-to-today) request.
    let yesterdayKey = try #require(
      calendar.date(byAdding: .day, value: -1, to: today).map(formatter.string(from:))
    )
    let bundle = try makeService(
      exchangeRates: [yesterdayKey: ["AUD": dec("1.5385")]]
    )

    let future1 = try #require(calendar.date(byAdding: .day, value: 7, to: today))
    let future2 = try #require(calendar.date(byAdding: .day, value: 30, to: today))
    _ = try await bundle.service.convert(dec("1"), from: usd, to: aud, on: future1)
    _ = try await bundle.service.convert(dec("1"), from: usd, to: aud, on: future2)

    #expect(await bundle.service.cachedRateCountForTesting == 1)
  }

  // MARK: - Invalidation

  /// `invalidateCache(for:)` drops every cache entry mentioning the
  /// instrument — required so a status-change on a crypto registration
  /// (e.g. user-flagged spam) is honoured by the next aggregation pass.
  @Test
  func invalidateCacheRemovesEntriesInvolvingInstrument() async throws {
    let registration = CryptoRegistration(
      instrument: eth,
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        binanceSymbol: "ETHUSDT"
      ),
      pricingStatus: .priced
    )
    let day = try date("2025-06-15")
    let bundle = try makeService(
      cryptoPrices: ["1:native": ["2025-06-15": dec("1600")]],
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5385")]],
      registrations: [registration]
    )

    _ = try await bundle.service.convert(dec("1"), from: eth, to: usd, on: day)
    _ = try await bundle.service.convert(dec("1"), from: usd, to: aud, on: day)
    #expect(await bundle.service.cachedRateCountForTesting == 2)

    await bundle.service.invalidateCache(for: eth)

    // The ETH→USD entry is dropped; USD→AUD survives.
    #expect(await bundle.service.cachedRateCountForTesting == 1)
  }

  // MARK: - Crypto unit-rate caching

  @Test
  func repeatedCryptoConvertsPopulateOneCacheEntry() async throws {
    let registration = CryptoRegistration(
      instrument: eth,
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        binanceSymbol: "ETHUSDT"
      ),
      pricingStatus: .priced
    )
    let day = try date("2025-06-15")
    let bundle = try makeService(
      cryptoPrices: ["1:native": ["2025-06-15": dec("1600")]],
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5385")]],
      registrations: [registration]
    )

    for _ in 0..<3 {
      let result = try await bundle.service.convert(
        dec("2"), from: eth, to: aud, on: day)
      #expect(result == dec("2") * dec("1600") * dec("1.5385"))
    }

    #expect(await bundle.service.cachedRateCountForTesting == 1)
  }
}
