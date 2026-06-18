import Foundation
import GRDB
import OSLog

/// Full conversion service supporting fiat-to-fiat, stock-to-fiat, and crypto conversions.
/// Stock-to-fiat routes through StockPriceService for price lookup, then ExchangeRateService
/// if the listing currency differs from the target fiat.
/// Crypto routes through CryptoPriceService (USD prices) then ExchangeRateService for non-USD fiat.
actor FullConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService
  private let stockPrices: StockPriceService
  private let cryptoPrices: CryptoPriceService?
  private let cryptoRegistrations: @Sendable () async throws -> [CryptoRegistration]
  private let logger = Logger(subsystem: "com.moolah.app", category: "CurrencyConversion")
  /// Database used by `observeRates()` to watch the live price-cache
  /// tables. Optional so existing test fixtures that don't observe
  /// rates can keep their construction call unchanged — when nil,
  /// `observeRates()` emits a single tick on subscription and
  /// `observeErrors()` returns an empty stream.
  private let database: (any DatabaseWriter)?
  /// Shared error channel for `observeRates()`. See
  /// `ObservationErrorChannel` doc for the surface-then-finish contract.
  private let errorChannel: ObservationErrorChannel?

  /// Per-(source, target, day) memo of the unit conversion factor.
  /// `convert(quantity:)` applies it as `(quantity * multiplier) /
  /// divisor` so that paths whose closed form is a division (fiat →
  /// crypto, crypto → crypto) preserve `Decimal` precision — eagerly
  /// computing `multiplier / divisor` would truncate at 38 digits and
  /// produce `0.99999…` for inputs that should give exactly `1`.
  ///
  /// Collapses the cold-launch burst of N identical convert calls
  /// (≈1400 in 1 s on a populated profile, issue #868) to one
  /// underlying lookup per distinct triple, skipping both the actor
  /// hop into the price services and the per-call `os_log` pair. Same
  /// staleness model as the underlying services' in-memory caches —
  /// cleared by `invalidateCache(for:)` for entries mentioning the
  /// instrument.
  private struct RateCacheKey: Hashable {
    let fromId: String
    let toId: String
    let day: Date
  }

  private struct UnitFactor {
    let multiplier: Decimal
    let divisor: Decimal
  }

  private var rateCache: [RateCacheKey: UnitFactor] = [:]

  /// UTC calendar — the underlying price services key their stored
  /// rates by UTC day, so the memo bucket must agree to avoid
  /// returning a stale rate across a UTC midnight boundary that's
  /// still "the same day" in the user's local timezone.
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }()

  /// Number of distinct `(source, target, day)` triples currently
  /// memoised. Test-only accessor — kept with the `ForTesting` suffix
  /// per `guides/DATABASE_CODE_GUIDE.md` §7 so the production API
  /// surface stays clean. Exposed for the caching-invariant tests in
  /// `FullConversionServiceCachingTests` so they can assert that
  /// repeated identical calls collapse to a single cache entry.
  var cachedRateCountForTesting: Int { rateCache.count }

  /// - Parameter cryptoRegistrations: Closure invoked on each crypto
  ///   conversion to obtain the current set of crypto registrations. Tokens
  ///   registered via `CryptoPriceService` after service construction become
  ///   resolvable on the next conversion without rebuilding the service.
  ///   Errors thrown by the closure (e.g. registry read failures) propagate
  ///   through `convert(_:from:to:on:)` rather than collapsing silently to an
  ///   empty mapping table — see `guides/INSTRUMENT_CONVERSION_GUIDE.md`
  ///   Rule 11.
  ///
  ///   Returning the full `CryptoRegistration` (rather than just its
  ///   `mapping`) is required so `convertResult(...)` can honour the
  ///   `pricingStatus` (`.priced` / `.unpriced` / `.spam`) per the
  ///   discriminated `CryptoPriceLookup` flow.
  init(
    exchangeRates: ExchangeRateService,
    stockPrices: StockPriceService,
    cryptoPrices: CryptoPriceService? = nil,
    cryptoRegistrations: @Sendable @escaping () async throws -> [CryptoRegistration] = { [] },
    database: (any DatabaseWriter)? = nil
  ) {
    self.exchangeRates = exchangeRates
    self.stockPrices = stockPrices
    self.cryptoPrices = cryptoPrices
    self.cryptoRegistrations = cryptoRegistrations
    self.database = database
    self.errorChannel = database == nil ? nil : ObservationErrorChannel()
  }

  func convert(
    _ quantity: Decimal,
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> Decimal {
    if source == target { return quantity }

    // Frankfurter (and the crypto/stock providers) have no future rates.
    // Forecast and scheduled-transaction call sites legitimately pass
    // `transaction.date` which can be in the future — clamp to today so
    // we resolve against the latest available rate instead of throwing.
    // See guides/INSTRUMENT_CONVERSION_GUIDE.md Rule 7.
    let effectiveDate = min(date, Date())
    let factor = try await unitFactor(from: source, to: target, on: effectiveDate)
    return (quantity * factor.multiplier) / factor.divisor
  }

  /// Resolves the per-unit conversion factor for `source → target` on
  /// `date`, caching the result keyed by `(source.id, target.id,
  /// calendar-day)`. Cache misses log at `.debug`; cache hits are
  /// silent. Logging at `.info` for every call (the historic shape)
  /// cost ≈2800 `os_log` lines in <1 s during the cold-launch burst
  /// documented in issue #868.
  private func unitFactor(
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> UnitFactor {
    let key = RateCacheKey(
      fromId: source.id,
      toId: target.id,
      day: calendar.startOfDay(for: date)
    )
    if let cached = rateCache[key] {
      return cached
    }

    logger.debug(
      "Converting 1 from \(source.id, privacy: .public) (\(String(describing: source.kind), privacy: .public)) to \(target.id, privacy: .public) (\(String(describing: target.kind), privacy: .public))"
    )

    let factor = try await computeUnitFactor(from: source, to: target, on: date)

    logger.debug(
      "Conversion factor: ×\(factor.multiplier, privacy: .public) ÷\(factor.divisor, privacy: .public) for \(target.id, privacy: .public)"
    )
    rateCache[key] = factor
    return factor
  }

  private func computeUnitFactor(
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> UnitFactor {
    switch (source.kind, target.kind) {
    case (.fiatCurrency, .fiatCurrency):
      let rate = try await exchangeRates.rate(from: source, to: target, on: date)
      return UnitFactor(multiplier: rate, divisor: Decimal(1))

    case (.stock, .fiatCurrency):
      let perUnit = try await convertStockToFiat(
        Decimal(1), stock: source, fiat: target, on: date)
      return UnitFactor(multiplier: perUnit, divisor: Decimal(1))

    case (.cryptoToken, .fiatCurrency):
      let perUnit = try await convertCryptoToFiat(
        Decimal(1), crypto: source, fiat: target, on: date)
      return UnitFactor(multiplier: perUnit, divisor: Decimal(1))

    case (.fiatCurrency, .cryptoToken):
      // Defer division so `300_000 JPY → ETH` at `1 ETH = 300_000 JPY`
      // yields exactly `Decimal(1)` instead of `0.999…`.
      let oneUnitInFiat = try await convertCryptoToFiat(
        Decimal(1), crypto: target, fiat: source, on: date)
      return UnitFactor(multiplier: Decimal(1), divisor: oneUnitInFiat)

    case (.cryptoToken, .cryptoToken):
      // Same precision concern: keep numerator and denominator separate
      // so `(quantity * sourceUsdPrice) / targetUsdPrice` matches the
      // original closed form.
      let sourceUsdPrice = try await cryptoUsdPrice(for: source, on: date)
      let targetUsdPrice = try await cryptoUsdPrice(for: target, on: date)
      return UnitFactor(multiplier: sourceUsdPrice, divisor: targetUsdPrice)

    case (.stock, .cryptoToken):
      // `result = quantity * stockUsdValueAt1 / cryptoUsdPrice(target)`.
      let stockUsdValueAt1 = try await convertStockToFiat(
        Decimal(1), stock: source, fiat: Instrument.USD, on: date)
      let targetUsdPrice = try await cryptoUsdPrice(for: target, on: date)
      return UnitFactor(multiplier: stockUsdValueAt1, divisor: targetUsdPrice)

    case (.cryptoToken, .stock),
      (.fiatCurrency, .stock),
      (.stock, .stock):
      throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
    }
  }

  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date
    )
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  /// Discriminated convert. When the source instrument is a crypto token
  /// whose registration carries a non-`.priced` `pricingStatus` (i.e.
  /// `.unpriced` or `.spam`), returns `.knownZero(targetInstrument:)`
  /// without invoking any price provider. Otherwise wraps the existing
  /// `convertAmount` in `.value(...)`. A real provider failure throws —
  /// per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11, never collapsed
  /// to `.knownZero`.
  ///
  /// Same-instrument identity is a fast path — even for `.unpriced` /
  /// `.spam` tokens — because the position list still wants to render
  /// the native quantity for the user (the token isn't worth zero ETH
  /// of itself; its *fiat aggregation* contribution is zero).
  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult {
    if amount.instrument == instrument {
      return .value(amount)
    }
    if amount.instrument.kind == .cryptoToken {
      let registrations = try await cryptoRegistrations()
      if let registration = registrations.first(where: { $0.id == amount.instrument.id }),
        registration.pricingStatus != .priced
      {
        // `.unpriced` and `.spam` resolve to a clean zero in the
        // requested target instrument without a provider call.
        return .knownZero(targetInstrument: instrument)
      }
      // `.priced` crypto: a date before the token's first confirmed trade has
      // no market value yet. Map `beforeFirstTrade` to `.knownZero` so
      // aggregation sites keep the day in the net-worth chart (contributing $0)
      // rather than dropping it. All other errors still propagate per Rule 11.
      do {
        return .value(try await convertAmount(amount, to: instrument, on: date))
      } catch CryptoPriceError.beforeFirstTrade {
        return .knownZero(targetInstrument: instrument)
      }
    }
    return .value(try await convertAmount(amount, to: instrument, on: date))
  }

  /// Invalidate any cached state held about `instrument`. Drops every
  /// memoised unit rate that mentions the instrument (either side), so
  /// the next aggregation re-fetches under the new pricing. For crypto
  /// instruments additionally clears the in-memory and on-disk price
  /// rows in `CryptoPriceService` — required after any user mutation
  /// that changes `pricingStatus` for the instrument's registration.
  func invalidateCache(for instrument: Instrument) async {
    var staleIds: Set<String> = [instrument.id]
    // A wrapped-native token is priced via its chain's native asset but
    // its unit rate is memoised under the wrapper's own id, so
    // invalidating the native asset must also evict the wrapper —
    // otherwise WETH keeps converting at the pre-update ETH rate.
    if instrument.kind == .cryptoToken, instrument.contractAddress == nil,
      let wrapperId = WrappedNativeContracts.canonicalWrappedInstrumentId(
        forChainId: instrument.chainId)
    {
      staleIds.insert(wrapperId)
    }
    rateCache = rateCache.filter { key, _ in
      !staleIds.contains(key.fromId) && !staleIds.contains(key.toId)
    }
    guard instrument.kind == .cryptoToken, let cryptoPrices else { return }
    await cryptoPrices.purgeCache(instrumentId: instrument.id)
  }

  // MARK: - Observation

  /// Reactive rate-tick stream. See protocol docs for the contract.
  /// When constructed without a database (test sites that don't
  /// observe), emits a single tick on subscription and never again —
  /// stores subscribing fire `recomputeConvertedTotals` once and stop,
  /// which is harmless.
  nonisolated func observeRates() -> AsyncStream<Void> {
    guard let database, let errorChannel else {
      return AsyncStream { continuation in
        continuation.yield(())
        continuation.finish()
      }
    }
    return makeRateCacheTickStream(
      database: database,
      errorChannel: errorChannel,
      repoMethod: "FullConversionService.observeRates")
  }

  nonisolated func observeErrors() -> AsyncStream<any Error> {
    guard let errorChannel else {
      return AsyncStream { $0.finish() }
    }
    return errorChannel.stream
  }

  // MARK: - Stock helpers

  private func convertStockToFiat(
    _ quantity: Decimal, stock: Instrument, fiat: Instrument, on date: Date
  ) async throws -> Decimal {
    guard let ticker = stock.ticker else {
      throw ConversionError.unsupportedConversion(from: stock.id, to: fiat.id)
    }
    let pricePerShare = try await stockPrices.price(ticker: ticker, on: date)
    let listingInstrument = try await stockPrices.instrument(for: ticker)
    let valueInListingCurrency = quantity * pricePerShare

    if listingInstrument.id == fiat.id {
      return valueInListingCurrency
    }

    let rate = try await exchangeRates.rate(from: listingInstrument, to: fiat, on: date)
    return valueInListingCurrency * rate
  }

  // MARK: - Crypto helpers

  private func convertCryptoToFiat(
    _ quantity: Decimal, crypto: Instrument, fiat: Instrument, on date: Date
  ) async throws -> Decimal {
    let usdPrice = try await cryptoUsdPrice(for: crypto, on: date)
    let usdValue = quantity * usdPrice
    if fiat.id == "USD" { return usdValue }
    let fiatRate = try await exchangeRates.rate(
      from: Instrument.USD, to: fiat, on: date
    )
    return usdValue * fiatRate
  }

  private func cryptoUsdPrice(for instrument: Instrument, on date: Date) async throws -> Decimal {
    guard let cryptoPrices else {
      throw ConversionError.noCryptoPriceService
    }
    let registrations = try await cryptoRegistrations()
    // Canonical wrapped-native tokens (WETH, WMATIC, …) have no price
    // feed of their own but are 1:1 redeemable for the chain's native
    // asset, so price them via the native registration. The match is an
    // exact `(chainId, contractAddress)` trust-list lookup — never by
    // symbol — so a spoofed look-alike cannot inherit the native price.
    let lookupId =
      WrappedNativeContracts.nativePricingInstrumentId(
        chainId: instrument.chainId, contractAddress: instrument.contractAddress)
      ?? instrument.id
    guard let registration = registrations.first(where: { $0.id == lookupId }) else {
      throw ConversionError.noProviderMapping(instrumentId: instrument.id)
    }
    return try await cryptoPrices.price(
      for: registration.instrument, mapping: registration.mapping, on: date)
  }

}
