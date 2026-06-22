import Foundation

/// Conversion pre-warm for `fetchDailyBalances`: collects the distinct
/// `(instrument, day-instant)` conversions the per-day walk will perform and
/// resolves them concurrently before the serial walk runs.
///
/// The per-day balance walk converts each held instrument to the profile
/// instrument *serially*, awaiting one rate at a time — on a populated
/// profile that is thousands of awaited conversions, and the first lookup
/// per `(token, date)` blocks on a network price fetch. Resolving the same
/// set up front, fanned out concurrently, overlaps those network fetches and
/// fills the conversion memo so the serial walk then hits warm caches. See
/// #1163.
extension GRDBAnalysisRepository {

  /// Collect the distinct `(instrument, day-instant)` conversions the
  /// per-day `walkDays` loop will perform, in day order. The instrument
  /// set is the running union seeded by the prior rows (which
  /// `seedPriorBook` installs from day zero) and grown by each day's
  /// deltas — mirroring `walkDays` + `applyDailyDeltas`. Each instrument
  /// is paired with that day's representative `sampleDate`, the same
  /// instant the walk converts on, so the warmed memo key matches the
  /// walk's conversion exactly. The profile instrument is excluded:
  /// `PositionBook.dailyBalance`'s same-instrument fast path never
  /// converts it.
  ///
  /// Over-approximates only harmlessly — wasted warm-ups, never a missed
  /// conversion that would change a result. Two known sources: an instrument
  /// whose post-cutoff position lives solely on an investment account (the
  /// walk reads it via `accountsFromTransfers`, not the bank sum, so some
  /// days are skipped); and trades-mode account instruments, which the
  /// separate `applyTradesModePositionValuations` fold converts at
  /// `startOfDay(for: sampleDate)` rather than `sampleDate`, a memo key this
  /// warm-up does not populate. Internal so `GRDBAnalysisPrewarmTests` can
  /// pin the running-union math.
  static func collectConversionWarmups(
    in aggregation: DailyBalancesAggregation,
    profileInstrument: Instrument
  ) -> [(instrument: Instrument, date: Date)] {
    let instrumentMap = aggregation.instrumentMap
    var active = Set<Instrument>()
    for row in aggregation.priorAccountRows {
      active.insert(resolveInstrument(row.instrumentId, in: instrumentMap))
    }
    for row in aggregation.priorEarmarkRows {
      active.insert(resolveInstrument(row.instrumentId, in: instrumentMap))
    }

    let accountByDay = Dictionary(grouping: aggregation.accountRows, by: \.day)
    let earmarkByDay = Dictionary(grouping: aggregation.earmarkRows, by: \.day)
    let allDayStrings = Set(accountByDay.keys).union(earmarkByDay.keys).sorted()

    var warmups: [(instrument: Instrument, date: Date)] = []
    for dayString in allDayStrings {
      let accountSlice = accountByDay[dayString] ?? []
      let earmarkSlice = earmarkByDay[dayString] ?? []
      for row in accountSlice {
        active.insert(resolveInstrument(row.instrumentId, in: instrumentMap))
      }
      for row in earmarkSlice {
        active.insert(resolveInstrument(row.instrumentId, in: instrumentMap))
      }
      let sample =
        accountSlice.first.map(\.sampleDate) ?? earmarkSlice.first.map(\.sampleDate)
      guard let sample else { continue }
      for instrument in active where instrument != profileInstrument {
        warmups.append((instrument: instrument, date: sample))
      }
    }
    return warmups
  }

  /// Concurrently resolve the collected warm-up conversions (bounded
  /// fan-out) so the underlying network price fetches overlap and the
  /// conversion memo is populated before the serial walk. Best-effort: a
  /// warm-up that fails is simply re-attempted — and its failure handled
  /// per the Rule 11 contract — by the walk, so failures are swallowed
  /// here and never alter the result.
  static func prewarmConversions(
    _ warmups: [(instrument: Instrument, date: Date)],
    to target: Instrument,
    using service: any InstrumentConversionService
  ) async {
    guard !warmups.isEmpty else { return }
    // Bounded fan-out: enough in-flight conversions to overlap the
    // per-(token, date) network price fetches, without flooding the
    // provider hosts (the HTTP layer rate-limits per host) or spawning a
    // task per day on a multi-year window. The conversion-service actor
    // serialises the memo writes regardless, so a higher cap buys nothing.
    let maxConcurrent = 16
    // A cancelled child rethrows `CancellationError` (see `warmOne`), which
    // surfaces from `group.next()`, tears the group down, and propagates out
    // — swallowed here because the pre-warm is best-effort: the serial walk
    // re-runs and rethrows cancellation authoritatively.
    try? await withThrowingTaskGroup(of: Void.self) { group in
      var next = 0
      let prime = min(maxConcurrent, warmups.count)
      while next < prime {
        let warmup = warmups[next]
        group.addTask { try await Self.warmOne(warmup, to: target, using: service) }
        next += 1
      }
      while try await group.next() != nil {
        guard next < warmups.count else { continue }
        let warmup = warmups[next]
        group.addTask { try await Self.warmOne(warmup, to: target, using: service) }
        next += 1
      }
    }
  }

  private static func warmOne(
    _ warmup: (instrument: Instrument, date: Date),
    to target: Instrument,
    using service: any InstrumentConversionService
  ) async throws {
    do {
      _ = try await service.convertResult(
        InstrumentAmount(quantity: 1, instrument: warmup.instrument), to: target, on: warmup.date)
    } catch is CancellationError {
      // Propagate cancellation so the group tears down promptly instead of
      // running the remaining warm-ups for a torn-down load.
      throw CancellationError()
    } catch {
      // Best-effort: a conversion that fails to warm is re-attempted — and
      // its failure handled per the Rule 11 per-day contract — by the serial
      // walk, so non-cancellation errors are intentionally discarded here.
    }
  }
}
