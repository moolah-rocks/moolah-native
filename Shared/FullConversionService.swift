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
  /// Per-instrument pricing resolver. Dispatches on `Instrument.kind` to a
  /// `PriceSource` that knows the instrument's unit price, its native quote
  /// currency, and its pricing status — the single surface the generic
  /// `factor` / `priceIn` algorithm and `convertResultDecision` consult,
  /// replacing the old per-kind helper switch.
  private let priceSources: PriceSourceResolver
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
  ///
  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  struct RateCacheKey: Hashable {
    let fromId: String
    let toId: String
    let day: Date
  }

  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  struct UnitFactor {
    let multiplier: Decimal
    let divisor: Decimal
  }

  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  var rateCache: [RateCacheKey: UnitFactor] = [:]

  /// UTC calendar — the underlying price services key their stored
  /// rates by UTC day, so the memo bucket must agree to avoid
  /// returning a stale rate across a UTC midnight boundary that's
  /// still "the same day" in the user's local timezone.
  ///
  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  let calendar: Calendar = {
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

  /// Crypto registration metadata (mapping + `pricingStatus`) is resolved by
  /// `CryptoPriceService` itself, via the keyed `metadataLookup` plug injected
  /// at its construction — no conversion code path scans the registry here.
  init(
    exchangeRates: ExchangeRateService,
    stockPrices: StockPriceService,
    cryptoPrices: CryptoPriceService? = nil,
    database: (any DatabaseWriter)? = nil
  ) {
    self.exchangeRates = exchangeRates
    self.stockPrices = stockPrices
    self.cryptoPrices = cryptoPrices
    self.priceSources = PriceSourceResolver(
      stockPrices: stockPrices, cryptoPrices: cryptoPrices)
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

  /// Computes the per-unit `source → target` factor as a precision-safe
  /// `(multiplier, divisor)` pair (division deferred to `convert`). Selects a
  /// single *common quote* both operands are priced into — the target fiat,
  /// else the source fiat, else USD — and prices each operand into it via
  /// `priceIn`. This one rule reproduces every prior per-kind case exactly,
  /// including FX direction and the exact-round-trip property: routing
  /// `fiat↔crypto` / `fiat↔stock` through the fiat operand (never USD) keeps
  /// `300_000 JPY → ETH` at `1 ETH = 300_000 JPY` returning exactly `1`.
  ///
  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  func computeUnitFactor(
    from source: Instrument,
    to target: Instrument,
    on date: Date
  ) async throws -> UnitFactor {
    // any → stock is unsupported (unchanged precondition).
    guard target.kind != .stock else {
      throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
    }
    if source == target { return UnitFactor(multiplier: Decimal(1), divisor: Decimal(1)) }
    if source.kind == .fiatCurrency, target.kind == .fiatCurrency {
      // Direct Frankfurter pair — never USD-triangulated.
      let rate = try await exchangeRates.rate(from: source, to: target, on: date)
      return UnitFactor(multiplier: rate, divisor: Decimal(1))
    }
    let common: Instrument =
      target.kind == .fiatCurrency
      ? target
      : source.kind == .fiatCurrency ? source : .USD
    let multiplier = try await priceIn(source, quotedIn: common, on: date)
    let divisor = try await priceIn(target, quotedIn: common, on: date)
    return UnitFactor(multiplier: multiplier, divisor: divisor)
  }

  /// Value of one unit of `instrument` expressed in `common`. Fiat resolves
  /// through the direct exchange-rate pair; stock / crypto price in their
  /// native quote (stock: listing currency; crypto: USD) and FX-convert to
  /// `common` only when it differs.
  private func priceIn(
    _ instrument: Instrument,
    quotedIn common: Instrument,
    on date: Date
  ) async throws -> Decimal {
    if instrument == common { return Decimal(1) }
    if instrument.kind == .fiatCurrency {
      return try await exchangeRates.rate(from: instrument, to: common, on: date)
    }
    let quote = try await priceSources.source(for: instrument).quote(on: date)
    if quote.nativeQuote.id == common.id { return quote.perUnit }
    let fxRate = try await exchangeRates.rate(from: quote.nativeQuote, to: common, on: date)
    return quote.perUnit * fxRate
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
    switch try await convertResultDecision(amount, to: instrument) {
    case .value(let amount):
      return .value(amount)
    case .knownZero:
      return .knownZero(targetInstrument: instrument)
    case .convert:
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
  }

  /// The no-provider-call part of the `convertResult` decision, shared by
  /// `convertResult` and `convertResultBatch` so the same-instrument /
  /// known-zero classification cannot drift between them. Crypto pricing
  /// status is read through the source's `PriceSource` (a cached metadata
  /// point-lookup — never a network call), so no registry scan happens here.
  ///
  /// `.convert` means the request needs a unit-factor resolution (and, for
  /// `.priced` crypto, may still resolve to `.knownZero` if it predates the
  /// first trade — handled by the caller after the provider call).
  ///
  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  enum ConvertResultDecision {
    case value(InstrumentAmount)
    case knownZero
    case convert
  }

  /// internal (not private) so FullConversionService+Batch.swift can reach it.
  func convertResultDecision(
    _ amount: InstrumentAmount,
    to instrument: Instrument
  ) async throws -> ConvertResultDecision {
    if amount.instrument == instrument {
      return .value(amount)
    }
    if amount.instrument.kind == .cryptoToken {
      // `pricingStatus` is date-independent for crypto (registration status
      // doesn't vary by day); a missing registration reports `.priced` so the
      // error surfaces later at price-fetch time rather than masquerading as
      // a clean zero here. A genuine registry / DB error (or cancellation)
      // propagates rather than being swallowed. `.unpriced` / `.spam` resolve
      // to a zero in the requested target instrument without a provider call.
      let status = try await priceSources.source(for: amount.instrument).pricingStatus()
      if status != .priced { return .knownZero }
    }
    return .convert
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

}
