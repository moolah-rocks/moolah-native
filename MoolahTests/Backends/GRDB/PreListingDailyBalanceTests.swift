import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end scenario tests verifying that a crypto token with a confirmed
/// `firstTradedOn` floor contributes $0 to the daily-balance net-worth for
/// any date strictly before the floor, while dates on or after the floor
/// receive the token's real market price — and that no day in the window
/// is dropped.
///
/// **Why this matters:** An airdrop token received before its listing date
/// has no market price on those pre-listing dates. Without the `beforeFirstTrade`
/// guard the conversion call would throw, dropping the whole net-worth day from
/// the chart. The fix maps pre-floor dates to `.knownZero`, which folds to
/// zero in `PositionBook.convert` — the day is retained and the token
/// contributes $0, while any other holdings in the same window still display.
///
/// **Wiring:** `CloudKitAnalysisTestBackend` accepts a custom
/// `InstrumentConversionService`. We build a `PreListingConversionService`
/// (a thin test-only type that returns `.knownZero` for the airdrop token
/// before the floor date and a real converted value on/after). This drives
/// the full `fetchDailyBalances` → `PositionBook.convert` → `convertResult`
/// pipeline against a real in-memory GRDB database.
///
/// The zone-invariance test drives `CryptoPriceService.priceLookup` directly
/// with noon-UTC day tokens in multiple timezones, verifying the
/// `dateString < firstTradedOn` string comparison is UTC-anchored and does
/// not drift a calendar day in UTC-negative zones.
@Suite("PreListing daily-balance scenario")
struct PreListingDailyBalanceTests {

  // MARK: - Instruments

  /// Simulated airdrop token: received before listing (pre-listing zero period).
  private let airdropInstrument = Instrument.crypto(
    chainId: 1,
    contractAddress: "0xairdrop",
    symbol: "DROP",
    name: "AirdropToken",
    decimals: 18
  )
  private let airdropMapping = CryptoProviderMapping(
    instrumentId: "1:0xairdrop",
    coingeckoId: "airdroptoken",
    binanceSymbol: nil
  )

  /// Normally-priced USD-denominated stable coin held alongside the airdrop.
  private let stableInstrument = Instrument.USD

  /// First-trade floor: provider has prices from this date onward.
  private let firstTrade = "2024-10-01"

  // MARK: - Helpers

  /// Parses an ISO `YYYY-MM-DD` string into a noon-UTC `Date`.
  ///
  /// Noon UTC is the canonical day-token used by the daily-balance walk
  /// (`FinancialMonth.date(forKey:)` anchors at noon UTC). Seeding transactions
  /// at noon UTC ensures `DATE(t.date)` (UTC calendar) groups them under the
  /// expected day string, and `Calendar(identifier: .gregorian).startOfDay` on
  /// the sampleDate produces a consistent local day key regardless of the test
  /// runner's timezone. Mirrors `AnalysisTestHelpers.utcDate(year:month:day:hour:12)`.
  private func noonUTCDate(year: Int, month: Int, day: Int) throws -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "UTC"))
    return try #require(
      cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
  }

  private func isoDate(_ string: String) throws -> Date {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    return try #require(fmt.date(from: string))
  }

  /// Gregorian calendar (inherits local timezone), matching `PositionBook.dailyBalance`'s
  /// day-key calendar so `startOfDay` comparisons line up.
  private let localCal = Calendar(identifier: .gregorian)

  /// Seeds the scenario backend: two accounts and three transactions.
  /// Returns the dates used for the two seeded day-groups.
  private func seedScenarioBackend(
    _ backend: CloudKitAnalysisTestBackend
  ) async throws -> (preFloor: Date, onFloor: Date) {
    try await backend.instrumentRegistry.registerResolvable(airdropInstrument)

    let usdAccount = Account(
      id: UUID(), name: "USD Cash", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(usdAccount)
    let airdropAccount = Account(
      id: UUID(), name: "Airdrop Wallet", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(airdropAccount)

    // Noon-UTC dates: UTC-anchored for consistent SQL DATE() grouping and
    // Calendar(identifier:.gregorian).startOfDay agreement across timezones.
    let preDateTxn = try noonUTCDate(year: 2024, month: 9, day: 25)
    let onFloorTxnDate = try noonUTCDate(year: 2024, month: 10, day: 1)

    // 10 DROP airdrop received pre-floor.
    _ = try await backend.transactions.create(
      Transaction(
        date: preDateTxn, payee: "Airdrop",
        legs: [
          TransactionLeg(
            accountId: airdropAccount.id, instrument: airdropInstrument,
            quantity: 10, type: .income)
        ]))
    // $200 USD same day (always priced).
    _ = try await backend.transactions.create(
      Transaction(
        date: preDateTxn, payee: "USD Salary",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: stableInstrument,
            quantity: 200, type: .income)
        ]))
    // $100 USD on the floor day.
    _ = try await backend.transactions.create(
      Transaction(
        date: onFloorTxnDate, payee: "USD Bonus",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: stableInstrument,
            quantity: 100, type: .income)
        ]))

    return (preDateTxn, onFloorTxnDate)
  }

  // MARK: - Scenario test

  /// End-to-end: pre-listing airdrop + normally-priced USD holding through
  /// the 2024-09-25…2024-10-01 window.
  ///
  /// (a) No day is dropped (both input dates produce a `DailyBalance`).
  /// (b) Pre-floor day (2024-09-25) values the airdrop at $0 while the
  ///     USD holding still contributes: 200 USD × 1.5 + 0 = 300 AUD.
  /// (c) On-floor day (2024-10-01) the airdrop converts at the real price:
  ///     300 + 100×1.5 + 10×50×1.5 = 1200 AUD cumulative.
  @Test("pre-listing airdrop values at $0 before floor; priced on/after — no days dropped")
  func preListingScenario() async throws {
    let floorDate = try isoDate(firstTrade)
    let conversion = PreListingConversionService(
      airdropInstrumentId: airdropInstrument.id,
      firstTradedOn: floorDate,
      airdropUSDPrice: dec("50.00"),
      usdToAUD: dec("1.5"))
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let (preDateTxn, onFloorTxnDate) = try await seedScenarioBackend(backend)

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nil)

    func balance(for date: Date) -> DailyBalance? {
      let key = localCal.startOfDay(for: date)
      return balances.first { daily in daily.date == key }
    }

    let sep25Balance = balance(for: preDateTxn)
    let sep25 = try #require(sep25Balance, "2024-09-25 must not be dropped")
    let oct01Balance = balance(for: onFloorTxnDate)
    let oct01 = try #require(oct01Balance, "2024-10-01 must not be dropped")

    // (b) Pre-floor: USD 200 × 1.5 = 300; DROP × $0 = 0.
    #expect(sep25.balance.instrument == .defaultTestInstrument)
    #expect(sep25.balance.quantity == 300, "2024-09-25: 200×1.5 + 0 = 300 AUD")

    // (c) On-floor cumulative: prior 300 + 100×1.5 + 10×50×1.5 = 1200.
    #expect(oct01.balance.instrument == .defaultTestInstrument)
    #expect(oct01.balance.quantity == 1200, "2024-10-01: 300 + 150 + 750 = 1200 AUD")
  }

  // MARK: - FullConversionService.convertResult end-to-end test

  /// `FullConversionService.convertResult` must return `.knownZero` for a
  /// `.priced` crypto token on dates strictly before `firstTradedOn`, and
  /// `.value` with the market price on dates on/after the floor.
  ///
  /// This pins the production seam: `convertResult` calls `convertAmount`
  /// which propagates `CryptoPriceError.beforeFirstTrade` from
  /// `CryptoPriceService.price(for:mapping:on:)`. Without the
  /// `catch CryptoPriceError.beforeFirstTrade` block in `convertResult`,
  /// the call throws rather than returning `.knownZero` — this test
  /// is RED before Fix A and GREEN after.
  ///
  /// Zone-invariance: 2024-09-30 noon UTC → `.knownZero`;
  /// 2024-10-01 noon UTC → `.value`. The boundary must not shift a day
  /// in UTC-negative zones (both tokens are noon-UTC so their ISO date
  /// strings are always "2024-09-30" / "2024-10-01" regardless of the
  /// ambient timezone).
  @Test("convertResult maps beforeFirstTrade to knownZero in FullConversionService")
  func fullConversionServiceConvertResultMapsBeforeFirstTradeToKnownZero() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try isoDate("2026-01-01")

    // Client that knows prices only on/after the firstTrade floor.
    let priceClient = FixedCryptoPriceClient(
      prices: ["1:0xairdrop": ["2024-10-01": dec("50.00")]],
      syncProvider: .coinGecko
    )
    let registration = CryptoRegistration(
      instrument: airdropInstrument, mapping: airdropMapping, pricingStatus: .priced)
    let registrationsById = [registration.id: registration]
    let cryptoService = CryptoPriceService(
      clients: [priceClient],
      database: database,
      metadataLookup: { registrationsById[$0] },
      now: { frozen }
    )

    // Inject cache metadata so CryptoPriceService knows the firstTradedOn floor
    // without a network round-trip. Prices on/after the floor are served by the
    // client above; the cache primes the floor sentinel so `price(for:mapping:on:)`
    // throws `beforeFirstTrade` for any date strictly before "2024-10-01".
    var series = SortedDateSeries<Decimal>()
    if let key = DateKey.from(isoString: "2024-10-01") {
      series.upsert(dec("50.00"), forKey: key)
    }
    await cryptoService.injectCacheForTesting(
      CryptoPriceCache(
        tokenId: "1:0xairdrop", symbol: "DROP",
        earliestDate: "2024-10-01", latestDate: "2024-10-01",
        prices: series, firstTradedOn: "2024-10-01"))

    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: [:]),
      database: database
    )
    let stockService = StockPriceService(client: FixedStockPriceClient(), database: database)
    let conversionService = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService
    )

    let amount = InstrumentAmount(quantity: dec("10"), instrument: airdropInstrument)

    // Pre-floor (noon UTC on 2024-09-30): must return .knownZero, not throw.
    let preBoundary = try noonUTCDate(year: 2024, month: 9, day: 30)
    let preResult = try await conversionService.convertResult(
      amount, to: stableInstrument, on: preBoundary)
    #expect(
      preResult == .knownZero(targetInstrument: stableInstrument),
      "2024-09-30 (before firstTradedOn) must yield .knownZero, got \(preResult)")

    // On-floor (noon UTC on 2024-10-01): must return .value with the market price.
    // The client has a price of 50.00 for "2024-10-01"; USD→USD, no FX conversion.
    // Expected: 10 DROP × 50 USD = 500 USD. Assert quantity sign/magnitude, not
    // currency symbol (locale-fragile).
    let onBoundary = try noonUTCDate(year: 2024, month: 10, day: 1)
    let onResult = try await conversionService.convertResult(
      amount, to: stableInstrument, on: onBoundary)
    guard case let .value(converted) = onResult else {
      Issue.record("2024-10-01 (on firstTradedOn) must yield .value, got \(onResult)")
      return
    }
    #expect(converted.instrument == stableInstrument)
    #expect(converted.quantity == dec("500"), "10 DROP × 50 USD/DROP = 500 USD")
  }

  // MARK: - Zone-invariance test

  /// Zone-invariance: the pre-listing boundary (2024-09-30 → `.knownZero`,
  /// 2024-10-01 → `.priced`) must NOT shift a day in UTC-negative zones.
  ///
  /// The boundary relies on `dateString < firstTradedOn` inside
  /// `CryptoPriceService.price(for:mapping:on:)`, where both sides are ISO
  /// `YYYY-MM-DD` strings produced by `ISO8601DateFormatter` with `.withFullDate`
  /// (always UTC-anchored). Noon-UTC day tokens (the shape produced by the
  /// daily-balance walk) are used so "2024-09-30 noon UTC" → "2024-09-30" and
  /// "2024-10-01 noon UTC" → "2024-10-01" regardless of the ambient zone.
  @Test("firstTradedOn boundary does not drift when asserted across UTC-negative zones")
  func firstTradedOnBoundaryIsZoneInvariant() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try isoDate("2026-01-01")
    let registration = CryptoRegistration(
      instrument: airdropInstrument, mapping: airdropMapping, pricingStatus: .priced)

    // Noon-UTC day tokens: zone-invariant by construction — all three timezones
    // must produce the same "2024-09-30" / "2024-10-01" date string.
    let preBoundary = try noonUTCDate(year: 2024, month: 9, day: 30)
    let onBoundary = try noonUTCDate(year: 2024, month: 10, day: 1)

    for zoneId in ["America/Los_Angeles", "UTC", "Australia/Brisbane"] {
      // Construct a FRESH service for each zone so that the service's internal
      // date formatter is initialised with the per-iteration timezone. This is
      // what proves the boundary does not shift: if the formatter were not
      // UTC-anchored, the LA service would misread "2024-09-30 noon UTC" as
      // "2024-09-29" and the knownZero/priced verdict would flip.
      let zone = try #require(TimeZone(identifier: zoneId))
      let cryptoClient = FixedCryptoPriceClient(prices: [
        "1:0xairdrop": ["2024-10-01": dec("50.00")]
      ])
      let cryptoService = CryptoPriceService(
        clients: [cryptoClient],
        database: database,
        now: { frozen },
        timeZone: zone)

      var series = SortedDateSeries<Decimal>()
      if let key = DateKey.from(isoString: "2024-10-01") {
        series.upsert(dec("50.00"), forKey: key)
      }
      await cryptoService.injectCacheForTesting(
        CryptoPriceCache(
          tokenId: "1:0xairdrop", symbol: "DROP",
          earliestDate: "2024-10-01", latestDate: "2024-10-01",
          prices: series, firstTradedOn: "2024-10-01"))

      let preLookup = try await cryptoService.priceLookup(for: registration, on: preBoundary)
      let onLookup = try await cryptoService.priceLookup(for: registration, on: onBoundary)
      #expect(
        preLookup == .knownZero,
        "2024-09-30 noon UTC must be .knownZero in \(zoneId); got \(preLookup)")
      #expect(
        onLookup == .priced(dec("50.00")),
        "2024-10-01 noon UTC must be .priced(50) in \(zoneId); got \(onLookup)")
    }
  }
}

// MARK: - PreListingConversionService

/// A date-aware `InstrumentConversionService` for testing the pre-listing
/// zero scenario. Returns `.knownZero` for the airdrop instrument on dates
/// strictly before `firstTradedOn`; on/after the floor converts at
/// `airdropUSDPrice × usdToAUD`. USD→AUD at the fixed `usdToAUD` rate for
/// the normally-priced stable coin. Same-instrument amounts pass through
/// unchanged.
private struct PreListingConversionService: InstrumentConversionService {
  let airdropInstrumentId: String
  let firstTradedOn: Date
  let airdropUSDPrice: Decimal
  let usdToAUD: Decimal

  private let inner: FakeConversionService

  init(
    airdropInstrumentId: String,
    firstTradedOn: Date,
    airdropUSDPrice: Decimal,
    usdToAUD: Decimal
  ) {
    self.airdropInstrumentId = airdropInstrumentId
    self.firstTradedOn = firstTradedOn
    self.airdropUSDPrice = airdropUSDPrice
    self.usdToAUD = usdToAUD
    self.inner = FakeConversionService.fixedRates(["USD": usdToAUD])
  }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    if from.id == to.id { return quantity }
    if from.id == airdropInstrumentId {
      if date < firstTradedOn { return 0 }
      return quantity * airdropUSDPrice * usdToAUD
    }
    return try await inner.convert(quantity, from: from, to: to, on: date)
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let qty = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: qty, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument { return .value(amount) }
    if amount.instrument.id == airdropInstrumentId, date < firstTradedOn {
      return .knownZero(targetInstrument: instrument)
    }
    let converted = try await convertAmount(amount, to: instrument, on: date)
    return .value(converted)
  }

  func invalidateCache(for instrument: Instrument) async {}

  func observeRates() -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuation.yield(())
      continuation.finish()
    }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}
