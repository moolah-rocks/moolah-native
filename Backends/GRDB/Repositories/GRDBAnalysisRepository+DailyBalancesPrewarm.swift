import Foundation

/// Conversion pre-warm for `fetchDailyBalances`. Splits the warm-up
/// collection and concurrent fan-out out of `+DailyBalances.swift` (sibling
/// to `+DailyBalancesAggregation.swift`, `+DailyBalancesForecast.swift`,
/// etc.).
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
  /// Over-approximates only harmlessly: an instrument whose post-cutoff
  /// position lives solely on an investment account (so the walk reads it
  /// via `accountsFromTransfers`, not the bank sum) may be warmed for a
  /// day the walk skips — a wasted cache hit, never a wrong result.
  /// Internal so `GRDBAnalysisPrewarmTests` can pin the running-union math.
  static func collectConversionWarmups(
    priorAccountRows: [DailyBalanceAccountRow],
    priorEarmarkRows: [DailyBalanceEarmarkRow],
    accountRows: [DailyBalanceAccountRow],
    earmarkRows: [DailyBalanceEarmarkRow],
    context: DailyBalancesAssemblyContext
  ) -> [(instrument: Instrument, date: Date)] {
    let profileInstrument = context.profileInstrument
    var active = Set<Instrument>()
    for row in priorAccountRows {
      active.insert(resolveInstrument(row.instrumentId, in: context.instrumentMap))
    }
    for row in priorEarmarkRows {
      active.insert(resolveInstrument(row.instrumentId, in: context.instrumentMap))
    }

    let accountByDay = Dictionary(grouping: accountRows, by: \.day)
    let earmarkByDay = Dictionary(grouping: earmarkRows, by: \.day)
    let allDayStrings = Set(accountByDay.keys).union(earmarkByDay.keys).sorted()

    var warmups: [(instrument: Instrument, date: Date)] = []
    for dayString in allDayStrings {
      let accountSlice = accountByDay[dayString] ?? []
      let earmarkSlice = earmarkByDay[dayString] ?? []
      for row in accountSlice {
        active.insert(resolveInstrument(row.instrumentId, in: context.instrumentMap))
      }
      for row in earmarkSlice {
        active.insert(resolveInstrument(row.instrumentId, in: context.instrumentMap))
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
    let maxConcurrent = 16
    await withTaskGroup(of: Void.self) { group in
      var next = 0
      let prime = min(maxConcurrent, warmups.count)
      while next < prime {
        let warmup = warmups[next]
        group.addTask { await Self.warmOne(warmup, to: target, using: service) }
        next += 1
      }
      while await group.next() != nil {
        // Stop scheduling more warm-ups once the owning task is cancelled
        // (the in-flight children drain at scope exit). The pre-warm is
        // best-effort, so there's nothing to salvage by continuing.
        guard !Task.isCancelled, next < warmups.count else { continue }
        let warmup = warmups[next]
        group.addTask { await Self.warmOne(warmup, to: target, using: service) }
        next += 1
      }
    }
  }

  private static func warmOne(
    _ warmup: (instrument: Instrument, date: Date),
    to target: Instrument,
    using service: any InstrumentConversionService
  ) async {
    _ = try? await service.convertResult(
      InstrumentAmount(quantity: 1, instrument: warmup.instrument), to: target, on: warmup.date)
  }
}
