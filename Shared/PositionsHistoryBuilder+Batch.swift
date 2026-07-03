import Foundation

// MARK: - Batch value conversion

/// The record-then-batch pass of `PositionsHistoryBuilder.build`: once the
/// fold pass (`+PositionsHistoryBuilder.swift`) has recorded every held
/// (instrument, day) pair as a `PendingDay`/`PendingEntry` without
/// converting anything, this file turns that flat list into one
/// `convertResultBatch` call and folds the outcomes back into
/// `BuildState.perInstrument` / `.total`.
extension PositionsHistoryBuilder {
  /// One held instrument on one day: the quantity to value and the
  /// cost-basis snapshot for that instrument on that day.
  struct PendingEntry {
    let instrument: Instrument
    let quantity: Decimal
    let cost: Decimal
  }

  /// One day's recorded points, captured during the fold pass before any
  /// conversion runs. `contributions` is the running cumulative
  /// contributions snapshot at that day (Rule 11 sticky latch).
  struct PendingDay {
    let day: Date
    let pointDate: Date
    let contributions: Decimal?
    var entries: [PendingEntry]
  }

  /// Record — without converting — one `PendingEntry` per held instrument
  /// on `day`, plus the day's contributions snapshot. Conversion happens
  /// later in one batch. `day` is UTC midnight (conversion key); `pointDate`
  /// is noon UTC (zone-invariant chart positioning token).
  func recordDailyPoints(
    for day: Date, state: BuildState
  ) -> PendingDay {
    let pointDate = Calendar.utc.date(byAdding: .hour, value: 12, to: day) ?? day
    var entries: [PendingEntry] = []
    for (instrument, qty) in state.quantities where qty != 0 {
      let cost = state.engine.openLots(for: instrument)
        .reduce(Decimal(0)) { $0 + $1.remainingCost }
      entries.append(PendingEntry(instrument: instrument, quantity: qty, cost: cost))
    }
    return PendingDay(
      day: day, pointDate: pointDate, contributions: state.contributions, entries: entries)
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
              contributions: nil))
          aggValue += amount.quantity
          aggCost += entry.cost
        case .knownZero:
          state.perInstrument[entry.instrument.id, default: []].append(
            HistoricalValueSeries.Point(
              date: pendingDay.pointDate,
              value: 0,
              cost: entry.cost,
              contributions: nil))
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
            contributions: pendingDay.contributions))
      }
    }
  }
}
