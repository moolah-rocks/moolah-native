import Foundation
import OSLog

/// Pure, async, throws-never helper that builds `[ValuedPosition]` for
/// `PositionsView` from a list of raw `Position`s plus an optional cost-basis
/// snapshot keyed by `Instrument.id`.
///
/// Per `guides/INSTRUMENT_CONVERSION_GUIDE.md`:
/// - Rule 8 (single-instrument fast path): rows whose instrument equals
///   `hostCurrency` skip the conversion service entirely.
/// - Rule 11 (per-row failure): a thrown conversion is logged and emitted as
///   a row with `value == nil`. Sibling rows still receive their successful
///   values. The aggregate visibility of the total / chart is the caller's
///   responsibility (see `PositionsViewInput.totalValue`).
///
/// `.knownZero` source instruments (`.unpriced` / `.spam` crypto
/// registrations) are dropped from the result entirely — issue #790. The
/// user triaged them via the inbox / "Mark as Spam" affordance and
/// shouldn't see them resurface in the account's positions table.
struct PositionsValuator: Sendable {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PositionsValuator")

  /// Build one `ValuedPosition` per input position whose conversion did
  /// not resolve to `.knownZero`.
  ///
  /// - Parameters:
  ///   - positions: raw quantities per instrument (zeroes filtered upstream).
  ///   - hostCurrency: target instrument for value/unitPrice/costBasis.
  ///   - costBasis: remaining cost basis per instrument id, expressed in
  ///     `hostCurrency`. Use `[:]` when no cost basis is known (flow context).
  ///   - on: valuation date.
  /// - Returns: surviving rows in input order. Failures map to `value == nil`;
  ///   `.knownZero` sources are dropped. Never throws.
  func valuate(
    positions: [Position],
    hostCurrency: Instrument,
    costBasis: [String: Decimal],
    on date: Date
  ) async -> [ValuedPosition] {
    // Phase 1 — accumulate one batch request per cross-instrument position;
    // same-instrument positions resolve inline (Rule 8 fast path) and never
    // contribute a request. Phase 2 — one batched conversion. Phase 3 —
    // assemble each position's row from its outcome slot (Rule 11 / #790).
    var requests: [BatchConversionRequest] = []
    requests.reserveCapacity(positions.count)
    for position in positions where position.instrument != hostCurrency {
      requests.append(
        BatchConversionRequest(
          amount: InstrumentAmount(
            quantity: position.quantity, instrument: position.instrument),
          target: hostCurrency,
          date: date))
    }

    // Cooperative cancellation now surfaces as a thrown `CancellationError`
    // from the batch; the consuming `.task(id:)` is torn down (filter change
    // / unmount) so we return what we have (nothing) and let the caller
    // re-check `Task.isCancelled` before publishing.
    let outcomes: [BatchConversionOutcome]
    do {
      outcomes = try await conversionService.convertResultBatch(requests)
    } catch {
      return []
    }

    var rows: [ValuedPosition] = []
    rows.reserveCapacity(positions.count)
    // Advances only for cross-instrument positions, so it indexes `outcomes`
    // in the same order Phase 1 appended their requests; same-instrument
    // positions take the fast path below and never consume an outcome.
    var cursor = 0
    for position in positions {
      let cost: InstrumentAmount? = costBasis[position.instrument.id].map {
        InstrumentAmount(quantity: $0, instrument: hostCurrency)
      }
      if position.instrument == hostCurrency {
        rows.append(
          ValuedPosition(
            instrument: position.instrument,
            quantity: position.quantity,
            unitPrice: nil,
            costBasis: cost,
            value: InstrumentAmount(quantity: position.quantity, instrument: hostCurrency)))
        continue
      }
      defer { cursor += 1 }
      if let entry = row(
        for: position, hostCurrency: hostCurrency, cost: cost, outcome: outcomes[cursor])
      {
        rows.append(entry)
      }
    }
    return rows
  }

  /// Assemble one cross-instrument position's row from its batch outcome.
  /// `.knownZero` drops the row (returns `nil`, #790); `.value` builds the
  /// valued row; `.failure` logs and emits a `value == nil` row (Rule 11).
  private func row(
    for position: Position,
    hostCurrency: Instrument,
    cost: InstrumentAmount?,
    outcome: BatchConversionOutcome
  ) -> ValuedPosition? {
    switch outcome {
    case .knownZero:
      // `.unpriced` / `.spam` crypto source — drop the row entirely
      // so it stops appearing in the account's positions table.
      // Issue #790.
      return nil
    case .value(let converted):
      let total = converted.quantity
      // For short positions (negative quantity), `total` and `position.quantity`
      // share the negative sign, so the quotient yields a positive per-unit price
      // — the natural reading of "what one share is worth right now". The zero
      // guard prevents NaN from propagating into the rendered amount; we accept
      // that a service returning total == 0 yields unitPrice == 0 (which is rare
      // and visually obvious as "free", which is correct for the data we have).
      let unit: InstrumentAmount? =
        position.quantity == 0
        ? nil
        : InstrumentAmount(quantity: total / position.quantity, instrument: hostCurrency)
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: unit,
        costBasis: cost,
        value: converted
      )
    case .failure(let error):
      logger.warning(
        "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: cost,
        value: nil
      )
    }
  }
}
