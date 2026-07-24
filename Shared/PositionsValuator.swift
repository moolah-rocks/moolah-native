import Foundation
import OSLog

/// Pure, async, throws-never helper that builds `[ValuedPosition]` for
/// the positions surface from a list of raw `Position`s plus an optional cost-basis
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

  private struct CrossInstrumentRowInput {
    let position: Position
    let cost: InstrumentAmount?
    let outcome: BatchConversionOutcome
    let accountChainId: Int?
    let oldestPriceDate: Date?
  }

  private struct RowBuildContext {
    let hostCurrency: Instrument
    let costBasis: [String: Decimal]
    let outcomes: [BatchConversionOutcome]
    let oldestPriceDates: [Date?]
    let accountChainId: Int?
  }

  private struct IndexedPriceDate: Sendable {
    let index: Int
    let date: Date?
  }

  /// Build one `ValuedPosition` per input position whose conversion did
  /// not resolve to `.knownZero`.
  ///
  /// - Parameters:
  ///   - positions: raw quantities per instrument (zeroes filtered upstream).
  ///   - hostCurrency: target instrument for value/unitPrice/costBasis.
  ///   - costBasis: remaining cost basis per instrument id, expressed in
  ///     `hostCurrency`. Use `[:]` when no cost basis is known (flow context).
  ///   - on: valuation date.
  ///   - accountChainId: the owning account's `Account.chainId`, stamped onto
  ///     every built row. Supply this only when the positions belong to a
  ///     single chain-scoped (crypto) account; pass `nil` (the default) for
  ///     multi-account group hosts and for exchange / manual accounts, where
  ///     no single owning chain applies. Feeds `AssetHolding.fold`'s
  ///     `contributingChainIds` derivation.
  /// - Returns: surviving rows in input order. Failures map to `value == nil`;
  ///   `.knownZero` sources are dropped. Never throws.
  func valuate(
    positions: [Position],
    hostCurrency: Instrument,
    costBasis: [String: Decimal],
    on date: Date,
    accountChainId: Int? = nil
  ) async -> [ValuedPosition] {
    // Phase 1 — accumulate one batch request per cross-instrument position;
    // same-instrument positions resolve inline (Rule 8 fast path) and never
    // contribute a request. Phase 2 — one batched conversion. Phase 3 —
    // assemble each position's row from its outcome slot (Rule 11 / #790).
    let requests = conversionRequests(
      for: positions, hostCurrency: hostCurrency, on: date)

    // Cooperative cancellation now surfaces as a thrown `CancellationError`
    // from the batch; the consuming `.task(id:)` is torn down (filter change
    // / unmount) so we return what we have (nothing) and let the caller
    // re-check `Task.isCancelled` before publishing.
    guard case .success(let outcomes) = await conversionOutcomes(for: requests) else {
      return []
    }
    guard
      case .success(let oldestPriceDates) =
        await priceDates(for: requests, outcomes: outcomes)
    else {
      return []
    }

    let context = RowBuildContext(
      hostCurrency: hostCurrency,
      costBasis: costBasis,
      outcomes: outcomes,
      oldestPriceDates: oldestPriceDates,
      accountChainId: accountChainId)
    return buildRows(from: positions, context: context)
  }

  private func conversionRequests(
    for positions: [Position],
    hostCurrency: Instrument,
    on date: Date
  ) -> [BatchConversionRequest] {
    positions.compactMap { position in
      guard position.instrument != hostCurrency else { return nil }
      return BatchConversionRequest(
        amount: InstrumentAmount(
          quantity: position.quantity, instrument: position.instrument),
        target: hostCurrency,
        date: date)
    }
  }

  private func conversionOutcomes(
    for requests: [BatchConversionRequest]
  ) async -> Result<[BatchConversionOutcome], CancellationError> {
    do {
      return .success(try await conversionService.convertResultBatch(requests))
    } catch {
      return .failure(CancellationError())
    }
  }

  private func priceDates(
    for requests: [BatchConversionRequest],
    outcomes: [BatchConversionOutcome]
  ) async -> Result<[Date?], CancellationError> {
    let conversionService = conversionService
    let logger = logger
    do {
      let dates = try await withThrowingTaskGroup(
        of: IndexedPriceDate.self,
        returning: [Date?].self
      ) { group in
        for (index, pair) in zip(requests, outcomes).enumerated() {
          let (request, outcome) = pair
          guard case .value = outcome else { continue }
          group.addTask {
            do {
              try Task.checkCancellation()
              let date = try await conversionService.oldestPriceDate(
                for: request.amount, to: request.target, on: request.date)
              try Task.checkCancellation()
              return IndexedPriceDate(index: index, date: date)
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              // Provenance is supplementary. A successfully converted value remains
              // usable if its date metadata cannot be recovered.
              logger.warning(
                "Failed to resolve price provenance for \(request.amount.instrument.id, privacy: .public) → \(request.target.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
              )
              return IndexedPriceDate(index: index, date: nil)
            }
          }
        }

        var dates = [Date?](repeating: nil, count: requests.count)
        for try await result in group {
          dates[result.index] = result.date
        }
        try Task.checkCancellation()
        return dates
      }
      return .success(dates)
    } catch {
      return .failure(CancellationError())
    }
  }

  private func buildRows(
    from positions: [Position],
    context: RowBuildContext
  ) -> [ValuedPosition] {
    var rows: [ValuedPosition] = []
    rows.reserveCapacity(positions.count)
    // Advances only for cross-instrument positions, so it indexes `outcomes`
    // in the same order Phase 1 appended their requests; same-instrument
    // positions take the fast path below and never consume an outcome.
    var cursor = 0
    for position in positions {
      let cost: InstrumentAmount? = context.costBasis[position.instrument.id].map {
        InstrumentAmount(quantity: $0, instrument: context.hostCurrency)
      }
      if position.instrument == context.hostCurrency {
        rows.append(
          ValuedPosition(
            instrument: position.instrument,
            quantity: position.quantity,
            unitPrice: nil,
            costBasis: cost,
            value: InstrumentAmount(
              quantity: position.quantity, instrument: context.hostCurrency),
            accountChainId: context.accountChainId))
        continue
      }
      defer { cursor += 1 }
      let input = CrossInstrumentRowInput(
        position: position,
        cost: cost,
        outcome: context.outcomes[cursor],
        accountChainId: context.accountChainId,
        oldestPriceDate: context.oldestPriceDates[cursor])
      if let entry = row(from: input, hostCurrency: context.hostCurrency) {
        rows.append(entry)
      }
    }
    return rows
  }

  /// Assemble one cross-instrument position's row from its batch outcome.
  /// `.knownZero` drops the row (returns `nil`, #790); `.value` builds the
  /// valued row; `.failure` logs and emits a `value == nil` row (Rule 11).
  private func row(
    from input: CrossInstrumentRowInput,
    hostCurrency: Instrument
  ) -> ValuedPosition? {
    switch input.outcome {
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
        input.position.quantity == 0
        ? nil
        : InstrumentAmount(quantity: total / input.position.quantity, instrument: hostCurrency)
      return ValuedPosition(
        instrument: input.position.instrument,
        quantity: input.position.quantity,
        unitPrice: unit,
        costBasis: input.cost,
        value: converted,
        accountChainId: input.accountChainId,
        oldestPriceDate: input.oldestPriceDate
      )
    case .failure(let error):
      logger.warning(
        "Failed to valuate position \(input.position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return ValuedPosition(
        instrument: input.position.instrument,
        quantity: input.position.quantity,
        unitPrice: nil,
        costBasis: input.cost,
        value: nil,
        accountChainId: input.accountChainId
      )
    }
  }
}
