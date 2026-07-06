import Foundation

// MARK: - Batch value conversion

/// The record-then-batch pass of `PositionsHistoryBuilder.build`: once the
/// fold pass (`+PositionsHistoryBuilder.swift`) has recorded every held
/// (instrument, day) pair as a `PendingDay`/`PendingEntry` without
/// converting anything, this file turns that flat list into one
/// `convertResultBatch` call and folds the outcomes back into
/// `BuildState.perInstrument` / `.total`.
extension PositionsHistoryBuilder {
  /// One held instrument on one day: the quantity to value and its remaining
  /// amount invested (per-instrument, from the profile-wide ledger) on that
  /// day.
  struct PendingEntry {
    let instrument: Instrument
    let quantity: Decimal
    let cost: Decimal
  }

  /// One day's recorded points, captured during the fold pass before any
  /// conversion runs. `invested` is the aggregate remaining amount invested
  /// at that day from the profile-wide ledger — `nil` when unavailable
  /// (Rule 11: an in-scope key failed conversion, or the ledger itself was
  /// unavailable). `nil` suppresses the aggregate baseline.
  struct PendingDay {
    let day: Date
    let pointDate: Date
    let invested: Decimal?
    var entries: [PendingEntry]
  }

  /// Record — without converting — one `PendingEntry` per held instrument
  /// on `day`, plus the day's aggregate remaining-invested snapshot, both
  /// read from the profile-wide `HoldingsCostLedger` (carrying forward the
  /// latest change-point at-or-before `day`). Conversion of the value line
  /// happens later in one batch. `day` is UTC midnight (conversion + ledger
  /// query key); `pointDate` is noon UTC (zone-invariant chart positioning
  /// token).
  ///
  /// A `nil` ledger (a genuine build failure at the call site) yields `nil`
  /// aggregate `invested` (baseline suppressed) and `0` per-instrument cost
  /// (that baseline suppressed too) — never a computed-looking figure from a
  /// failure. `Point.cost` is non-optional, so a per-instrument key that is
  /// unavailable in an otherwise-good ledger also coalesces to `0`
  /// (suppressed for that instrument); the aggregate `invested` faithfully
  /// preserves the ledger's `nil`.
  func recordDailyPoints(
    for day: Date, state: BuildState, accountIds: Set<UUID>, ledger: HoldingsCostLedger?
  ) -> PendingDay {
    let pointDate = Calendar.utc.date(byAdding: .hour, value: 12, to: day) ?? day
    var entries: [PendingEntry] = []
    for (instrument, qty) in state.quantities where qty != 0 {
      let cost =
        ledger.flatMap {
          $0.remainingInvested(accountIds: accountIds, instrument: instrument, onOrBefore: day)
        } ?? 0
      entries.append(PendingEntry(instrument: instrument, quantity: qty, cost: cost))
    }
    let invested = ledger.flatMap {
      $0.remainingInvested(accountIds: accountIds, onOrBefore: day)
    }
    return PendingDay(day: day, pointDate: pointDate, invested: invested, entries: entries)
  }

  /// Flatten every recorded `(instrument, day)` pair across `pending` into
  /// one `convertResultBatch` call. Throws on cancellation (or any other
  /// batch error) so the caller can bail without assembling.
  func convertPending(
    _ pending: [PendingDay], hostCurrency: Instrument
  ) async throws -> [BatchConversionOutcome] {
    if Task.isCancelled { throw CancellationError() }
    var requests: [BatchConversionRequest] = []
    for pendingDay in pending {
      for entry in pendingDay.entries {
        requests.append(
          BatchConversionRequest(
            amount: InstrumentAmount(quantity: entry.quantity, instrument: entry.instrument),
            target: hostCurrency,
            date: pendingDay.day))
      }
    }
    return try await conversionService.convertResultBatch(requests)
  }

  /// Fold the batch outcomes back into per-instrument and aggregate points.
  /// Outcomes are in request order — the same nested (day, entry) order the
  /// requests were built in — so a single running index re-pairs them.
  ///
  /// Rule 11: the aggregate/total point for a day is emitted only if no
  /// contributing instrument `.failure`d that day. `.knownZero` is an
  /// intentional zero (value 0, cost still counted) and keeps the day —
  /// matching `convertResult`'s documented net-worth-chart semantics
  /// (a spam / unpriced / pre-first-trade token no longer blanks the day's
  /// total the way the old per-day `convert` throw did).
  func assemble(
    pending: [PendingDay], outcomes: [BatchConversionOutcome], into state: inout BuildState
  ) {
    var index = 0
    for pendingDay in pending {
      var aggValue: Decimal = 0
      var aggCost: Decimal = 0
      var aggOK = true
      var anyHeld = false
      for entry in pendingDay.entries {
        anyHeld = true
        let outcome = outcomes[index]
        index += 1
        switch outcome {
        case .value(let amount):
          state.perInstrument[entry.instrument.id, default: []].append(
            HistoricalValueSeries.Point(
              date: pendingDay.pointDate,
              value: amount.quantity,
              cost: entry.cost,
              invested: nil))
          aggValue += amount.quantity
          aggCost += entry.cost
        case .knownZero:
          state.perInstrument[entry.instrument.id, default: []].append(
            HistoricalValueSeries.Point(
              date: pendingDay.pointDate,
              value: 0,
              cost: entry.cost,
              invested: nil))
          aggCost += entry.cost
        case .failure:
          aggOK = false
        }
      }
      if anyHeld && aggOK {
        state.total.append(
          HistoricalValueSeries.Point(
            date: pendingDay.pointDate,
            value: aggValue,
            cost: aggCost,
            invested: pendingDay.invested))
      }
    }
  }
}
