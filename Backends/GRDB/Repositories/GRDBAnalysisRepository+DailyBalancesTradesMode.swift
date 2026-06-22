import Foundation

/// Per-day position-valuation fold for trades-mode investment
/// accounts. Sister of `applyInvestmentValues` in
/// `+DailyBalancesInvestmentValues.swift` — same per-day Rule 11
/// error contract: only `CancellationError` throws from
/// `convertResultBatch` and rethrows immediately; a per-position
/// conversion failure arrives as a `.failure` outcome in the assemble
/// phase, which drops that day from `dailyBalances` and logs through
/// `handleInvestmentValueFailure`.
///
/// Paired with the recorded-value (snapshot) fold in
/// `+DailyBalancesInvestmentValues.swift`.
extension GRDBAnalysisRepository {

  // MARK: - Trades-mode per-day fold

  /// One decoded entry in the trades-mode cursor walk — a per-day,
  /// per-account, per-instrument quantity ready to apply to the
  /// cumulative `positions` dict.
  private struct TradesModePositionEntry {
    let dayKey: Date
    let accountId: UUID
    let instrument: Instrument
    let quantity: Decimal
  }

  /// One day's accumulated trades-mode plan: the day key (also the failure
  /// context), the synchronous fast-path subtotal (profile-instrument
  /// positions plus skipped zeros), and the number of foreign-position
  /// conversion requests this day contributed to the flat batch. The
  /// assemble pass slices `requestCount` outcomes back out per day in order.
  private struct TradesModeDayPlan {
    let dayKey: Date
    let fastPathTotal: Decimal
    let requestCount: Int
  }

  /// Per-day position-valuation fold for trades-mode investment
  /// accounts. Sister of `applyInvestmentValues` — same per-day error
  /// contract: only `CancellationError` throws from `convertResultBatch`
  /// and rethrows immediately; a per-position conversion failure arrives
  /// as a `.failure` outcome in the assemble phase, which drops that day
  /// from `dailyBalances` and logs through `handleInvestmentValueFailure`.
  ///
  /// Batched in three phases (same shape as `walkDays` and
  /// `applyInvestmentValues`): (1) walk `dailyBalances.keys.sorted()`,
  /// advancing the position cursor, and snapshot each day's
  /// foreign-position conversion requests *at that day's cumulative
  /// `positions` state* while accumulating the synchronous
  /// profile-instrument subtotal; (2) resolve every day's requests in a
  /// single `convertResultBatch(...)`; (3) merge each day's outcome slice
  /// into `dailyBalances`. The cursor walk MUST snapshot inside phase 1 —
  /// `positions` mutates cumulatively per day, so deriving requests
  /// afterwards would value every day at the final day's positions.
  ///
  /// For each output `dayKey`, the cursor advances through every entry
  /// with `entry.dayKey <= dayKey` — including entries for days absent
  /// from `dailyBalances` (e.g. dropped by an earlier snapshot-fold
  /// failure) — so cumulative position state stays correct on every
  /// following day.
  ///
  /// `priorRows` and `postRows` carry only rows whose `accountId`
  /// belongs to a trades-mode investment account — pre-filtered in
  /// `readDailyBalancesAggregation` so this fold neither re-checks
  /// membership nor walks rows for accounts it doesn't own.
  static func applyTradesModePositionValuations(
    priorRows: [DailyBalanceAccountRow],
    postRows: [DailyBalanceAccountRow],
    to dailyBalances: inout [Date: DailyBalance],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws {
    guard !context.tradesModeInvestmentAccountIds.isEmpty,
      !dailyBalances.isEmpty
    else { return }

    let (plans, requests) = accumulateTradesModeDays(
      priorRows: priorRows,
      postRows: postRows,
      days: dailyBalances.keys.sorted(),
      context: context)

    // The all-fast-path case produces an empty batch (no `await` inside),
    // so check cancellation explicitly before resolving.
    try Task.checkCancellation()
    let outcomes = try await context.conversionService.convertResultBatch(requests)

    assembleTradesModeDays(
      plans: plans,
      outcomes: outcomes,
      into: &dailyBalances,
      profileInstrument: context.profileInstrument,
      handlers: handlers)
  }

  /// Phase 1: walk the days in order, advancing the position cursor and
  /// snapshotting each day's foreign-position conversion requests at that
  /// day's cumulative `positions` state. Profile-instrument positions fold
  /// into the day's `fastPathTotal` synchronously (Rule 8 fast path);
  /// zero-quantity positions are skipped (a lingering instrument key after
  /// a same-day BUY+SELL nets out — there is no value in a `0 * rate` hop);
  /// foreign positions append one request to the flat batch. Days where
  /// `positions` is empty produce no plan (matching the old
  /// `positions.isEmpty` `continue`).
  private static func accumulateTradesModeDays(
    priorRows: [DailyBalanceAccountRow],
    postRows: [DailyBalanceAccountRow],
    days: [Date],
    context: DailyBalancesAssemblyContext
  ) -> (plans: [TradesModeDayPlan], requests: [BatchConversionRequest]) {
    var positions = seedTradesModePriorPositions(
      priorRows: priorRows, instrumentMap: context.instrumentMap)
    let entries = buildTradesModeEntries(
      postRows: postRows, instrumentMap: context.instrumentMap)
    let profileInstrument = context.profileInstrument

    var valueIndex = 0
    var plans: [TradesModeDayPlan] = []
    var requests: [BatchConversionRequest] = []
    for dayKey in days {
      // Advance the cursor: apply every entry on-or-before dayKey,
      // including those for days absent from dailyBalances.
      while valueIndex < entries.count, entries[valueIndex].dayKey <= dayKey {
        let entry = entries[valueIndex]
        positions[entry.accountId, default: [:]][entry.instrument, default: 0] +=
          entry.quantity
        valueIndex += 1
      }
      if positions.isEmpty { continue }
      var fastPathTotal: Decimal = 0
      var requestCount = 0
      for (_, perInstrument) in positions {
        for (instrument, quantity) in perInstrument {
          if quantity == 0 { continue }
          if instrument.id == profileInstrument.id {
            fastPathTotal += quantity
            continue
          }
          // dayKey is `Calendar.current.startOfDay(for: row.sampleDate)`
          // — same normalization as walkDays and the conversion-service
          // lookup.
          let amount = InstrumentAmount(quantity: quantity, instrument: instrument)
          requests.append(
            BatchConversionRequest(amount: amount, target: profileInstrument, date: dayKey))
          requestCount += 1
        }
      }
      plans.append(
        TradesModeDayPlan(
          dayKey: dayKey, fastPathTotal: fastPathTotal, requestCount: requestCount))
    }
    return (plans, requests)
  }

  /// Phase 3: slice the flat `outcomes` back out per day in the same order
  /// the requests were appended, folding each day's foreign-position
  /// outcomes into its `fastPathTotal` and merging the result into
  /// `dailyBalances`.
  ///
  /// Rule 11: a `.failure` in a day's slice drops that day from
  /// `dailyBalances` and logs once via `handleInvestmentValueFailure`.
  /// `.knownZero` (e.g. an `.unpriced` / `.spam` crypto position)
  /// contributes zero rather than failing the day — issue #790.
  private static func assembleTradesModeDays(
    plans: [TradesModeDayPlan],
    outcomes: [BatchConversionOutcome],
    into dailyBalances: inout [Date: DailyBalance],
    profileInstrument: Instrument,
    handlers: DailyBalancesHandlers
  ) {
    var cursor = 0
    for plan in plans {
      let slice = outcomes[cursor..<cursor + plan.requestCount]
      cursor += plan.requestCount
      var total = plan.fastPathTotal
      var failure: (any Error)?
      for outcome in slice {
        switch outcome {
        case .value(let converted):
          total += converted.quantity
        case .knownZero:
          break  // contributes zero
        case .failure(let error):
          failure = error
        }
      }
      if let failure {
        // Rule 11: drop the day from dailyBalances so the chart shows
        // a gap. Matches the walkDays / applyInvestmentValues
        // per-day error contract.
        handlers.handleInvestmentValueFailure(failure, plan.dayKey)
        dailyBalances.removeValue(forKey: plan.dayKey)
        continue
      }
      mergeTradesModeTotal(
        InstrumentAmount(quantity: total, instrument: profileInstrument),
        into: &dailyBalances,
        on: plan.dayKey,
        profileInstrument: profileInstrument)
    }
  }

  /// Pre-fold priors into a per-account, per-instrument cumulative
  /// dict. Decoding mirrors `applyDailyDeltas`: resolve the instrument
  /// via the registry, then convert the row's storage value into a
  /// Decimal quantity.
  private static func seedTradesModePriorPositions(
    priorRows: [DailyBalanceAccountRow],
    instrumentMap: [String: Instrument]
  ) -> [UUID: [Instrument: Decimal]] {
    var positions: [UUID: [Instrument: Decimal]] = [:]
    for row in priorRows {
      let instrument = resolveInstrument(row.instrumentId, in: instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      positions[row.accountId, default: [:]][instrument, default: 0] += quantity
    }
    return positions
  }

  /// Build a sorted cursor over post rows. Grouping by SQL `\.day`
  /// (UTC string) is intentionally avoided — the outer walk is over
  /// local-startOfDay `Date` keys, so we key the cursor at `dayKey`
  /// granularity directly to avoid Rule 10 timezone mismatch.
  private static func buildTradesModeEntries(
    postRows: [DailyBalanceAccountRow],
    instrumentMap: [String: Instrument]
  ) -> [TradesModePositionEntry] {
    var entries: [TradesModePositionEntry] = []
    entries.reserveCapacity(postRows.count)
    for row in postRows {
      let instrument = resolveInstrument(row.instrumentId, in: instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      entries.append(
        TradesModePositionEntry(
          dayKey: Calendar.current.startOfDay(for: row.sampleDate),
          accountId: row.accountId,
          instrument: instrument,
          quantity: quantity))
    }
    entries.sort { $0.dayKey < $1.dayKey }
    return entries
  }

  /// Merge a per-day trades-mode total into the existing
  /// `dailyBalances[dayKey]` row, summing into any
  /// recorded-value-fold-supplied `investmentValue` and recomputing
  /// `netWorth`. No-op when the day is absent (already dropped by
  /// an earlier failure).
  private static func mergeTradesModeTotal(
    _ total: InstrumentAmount,
    into dailyBalances: inout [Date: DailyBalance],
    on dayKey: Date,
    profileInstrument: Instrument
  ) {
    precondition(
      total.instrument == profileInstrument,
      "mergeTradesModeTotal: total must be in profileInstrument; got \(total.instrument.id)")
    guard let existing = dailyBalances[dayKey] else { return }
    let combined =
      (existing.investmentValue ?? .zero(instrument: profileInstrument)) + total
    dailyBalances[dayKey] = DailyBalance(
      date: existing.date,
      balance: existing.balance,
      earmarked: existing.earmarked,
      availableFunds: existing.availableFunds,
      investments: existing.investments,
      investmentValue: combined,
      netWorth: existing.balance + combined,
      bestFit: existing.bestFit,
      isForecast: existing.isForecast)
  }
}
