import Foundation

/// One element of a batch conversion request: convert `amount` into
/// `target` as of `date`. The trio mirrors the arguments of
/// `convertResult(_:to:on:)` so a caller can build a flat request list
/// and resolve it in a single `await`.
struct BatchConversionRequest: Sendable {
  let amount: InstrumentAmount
  let target: Instrument
  let date: Date
}

/// Per-element result of `convertResultBatch(_:)`. `.value` and
/// `.knownZero(targetInstrument:)` mirror `ConversionResult` so callers
/// reuse their Rule 11 folding; `.failure` carries the per-element error
/// so a single bad request degrades only its own row / day rather than
/// failing the whole batch.
///
/// Not `Equatable` — the `.failure` payload is `any Error`. Tests
/// pattern-match instead.
enum BatchConversionOutcome: Sendable {
  /// A converted amount in the request's target instrument.
  case value(InstrumentAmount)
  /// The source resolved to a clean zero in `targetInstrument` (an
  /// `.unpriced` / `.spam` token, or a `.priced` token before its first
  /// trade). Contributes exactly zero — never a failure.
  case knownZero(targetInstrument: Instrument)
  /// A real provider failure for this element. The caller applies its
  /// existing Rule 11 handling (log + drop the row / day, continue).
  case failure(any Error)
}

/// Converts quantities between instruments. Phase 2: fiat-to-fiat only.
/// Phase 3+ will add stock and crypto conversion paths.
protocol InstrumentConversionService: Sendable {
  /// Convert a raw quantity from one instrument to another on a given date.
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal

  /// Convenience: convert an InstrumentAmount to a different instrument.
  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount

  /// Discriminated convert. Returns `.knownZero(targetInstrument: to)`
  /// when the source instrument's provider mapping resolves to a
  /// `.knownZero` price (e.g. `.unpriced` or `.spam` crypto token).
  /// Returns `.value` on real conversions. Throws on provider failure —
  /// never collapses failure to `.knownZero`.
  ///
  /// Required for any aggregation path that needs to keep "intentional
  /// zero" distinct from "rate unavailable" per
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult

  /// Convert a batch of `(amount, target, date)` requests in one `await`,
  /// returning one `BatchConversionOutcome` per request in request order.
  ///
  /// Collapses N serial `convertResult` hops (per row / per day / per
  /// instrument in a history walk) into a single call so a conformer can
  /// overlap the underlying network fetches internally. The default
  /// implementation (in this file) loops `convertResult`; conformers that
  /// can dedup or parallelise — e.g. `FullConversionService` — override.
  ///
  /// Per-element failures surface as `.failure(error)`; only
  /// **cancellation** propagates, as a thrown `CancellationError`
  /// (cancellation is task-wide, not per-element). See
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11.
  func convertResultBatch(
    _ requests: [BatchConversionRequest]
  ) async throws -> [BatchConversionOutcome]

  /// Invalidate any cached state held about `instrument` (and any rate
  /// derived from it). Called when a user mutation changes
  /// `pricingStatus` for a crypto registration so the next aggregation
  /// reads fresh data. No-op for fiat instruments and for
  /// implementations that don't cache.
  func invalidateCache(for instrument: Instrument) async

  /// Reactive "rate-tick" stream. Emits one `Void` value when the
  /// service is subscribed (initial tick) and then re-emits whenever
  /// any of the live price-cache tables changes — `exchange_rate`
  /// (FX), `stock_price`, or `crypto_price`. Stores that compute
  /// converted balances subscribe and recompute on each tick so a
  /// remote sync write that updates a rate triggers UI refresh
  /// without a manual reload. The stream is non-throwing: errors
  /// surface out-of-band on `observeErrors()`.
  ///
  /// The conformance must use the explicit-region form
  /// `ValueObservation.tracking(regions:fetch:)` because the cache
  /// tables may be empty on a fresh-install profile. The inference
  /// form (`tracking { db in }` reading rows) only registers a table
  /// after the first row is read — fresh-install profiles would miss
  /// the first sync write to each cache table. See
  /// `guides/DATABASE_CODE_GUIDE.md` §2 convention 1.
  ///
  /// **No `removeDuplicates()`.** `Void == Void` would suppress every
  /// emission. The retry helper used elsewhere unconditionally chains
  /// `removeDuplicates()`, so this stream wires its own retry path
  /// (via the underlying `makeRetryingAsyncStream` driver, which has
  /// no `Equatable` requirement).
  func observeRates() -> AsyncStream<Void>

  /// Companion error stream for `observeRates()`. A healthy service
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes. Mirrors the
  /// `AccountRepository.observeErrors()` contract.
  func observeErrors() -> AsyncStream<any Error>
}

extension InstrumentConversionService {
  /// Default `convertResultBatch`: loops `convertResult` per request,
  /// folding each into `.value` / `.knownZero` / `.failure`. Checks for
  /// cancellation between elements and rethrows `CancellationError` so a
  /// cancelled batch never returns partial outcomes. The single test
  /// double and any conformer that does not override inherit this.
  func convertResultBatch(
    _ requests: [BatchConversionRequest]
  ) async throws -> [BatchConversionOutcome] {
    var outcomes: [BatchConversionOutcome] = []
    outcomes.reserveCapacity(requests.count)
    for request in requests {
      try Task.checkCancellation()
      do {
        let result = try await convertResult(
          request.amount, to: request.target, on: request.date)
        switch result {
        case .value(let amount):
          outcomes.append(.value(amount))
        case .knownZero(let targetInstrument):
          outcomes.append(.knownZero(targetInstrument: targetInstrument))
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        outcomes.append(.failure(error))
      }
    }
    return outcomes
  }
}

enum ConversionError: Error, Equatable {
  case unsupportedInstrumentKind
  case unsupportedConversion(from: String, to: String)
  case noCryptoPriceService
  case noProviderMapping(instrumentId: String)
}
