import Foundation
import GRDB

/// Fiat-to-fiat conversion backed by ExchangeRateService.
actor FiatConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService
  private let now: @Sendable () -> Date
  /// Database used by `observeRates()` to watch the live price-cache
  /// tables (`exchange_rate`, `stock_price`, `crypto_price`). Optional
  /// so the service stays usable in test fixtures that never observe
  /// rates — when nil, `observeRates()` emits a single tick on
  /// subscription and `observeErrors()` returns an empty stream.
  private let database: (any DatabaseWriter)?
  /// Shared with every `observeRates()` subscription returned by this
  /// instance. The channel is single-shot: once `surfaceAndFinish(_:)`
  /// is called every observation surfaces the same terminal error.
  private let errorChannel: ObservationErrorChannel?

  init(
    exchangeRates: ExchangeRateService,
    database: (any DatabaseWriter)? = nil,
    now: @Sendable @escaping () -> Date = { Date() }
  ) {
    self.exchangeRates = exchangeRates
    self.database = database
    self.now = now
    self.errorChannel = database == nil ? nil : ObservationErrorChannel()
  }

  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal {
    guard from != to else { return quantity }
    guard from.kind == .fiatCurrency, to.kind == .fiatCurrency else {
      throw ConversionError.unsupportedInstrumentKind
    }
    // Frankfurter has no future rates. Forecast and scheduled-transaction
    // call sites legitimately pass `transaction.date` which can be in the
    // future — clamp to today so we resolve against the latest available
    // rate instead of throwing. See guides/INSTRUMENT_CONVERSION_GUIDE.md
    // Rule 7.
    let effectiveDate = min(date, now())
    let rate = try await exchangeRates.rate(from: from, to: to, on: effectiveDate)
    return quantity * rate
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

  /// Discriminated convert. Fiat has no `.knownZero` concept (every
  /// `.fiatCurrency` instrument has a real rate), so this always wraps
  /// the existing `convertAmount` in `.value(...)` and propagates a
  /// thrown error unchanged. Aggregation callers can use this method
  /// uniformly across both fiat and crypto-aware services. Per
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11, a thrown error
  /// is never collapsed to `.knownZero`.
  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult {
    let converted = try await convertAmount(amount, to: instrument, on: date)
    return .value(converted)
  }

  func oldestPriceDate(
    for amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> Date? {
    guard amount.instrument != instrument else { return nil }
    guard amount.instrument.kind == .fiatCurrency, instrument.kind == .fiatCurrency else {
      throw ConversionError.unsupportedInstrumentKind
    }
    return try await exchangeRates.effectiveRateDate(
      from: amount.instrument,
      to: instrument,
      on: min(date, now()))
  }

  /// No-op: the fiat conversion cache lives in `ExchangeRateService` and
  /// is keyed by date, not by individual instrument. Crypto-specific
  /// invalidation only matters in `FullConversionService`.
  func invalidateCache(for instrument: Instrument) async {
    // Intentionally empty.
  }

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
      repoMethod: "FiatConversionService.observeRates")
  }

  nonisolated func observeErrors() -> AsyncStream<any Error> {
    guard let errorChannel else {
      return AsyncStream { $0.finish() }
    }
    return errorChannel.stream
  }
}
