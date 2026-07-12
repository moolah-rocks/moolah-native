import Foundation
import GRDB

/// Per-day position-valuation fold for every investment-like account.
/// It has the same per-day Rule 11
/// error contract: only `CancellationError` throws from
/// `convertResultBatch` and rethrows immediately; a per-position
/// conversion failure arrives as a `.failure` outcome in the assemble
/// phase, which drops that day from `dailyBalances` and logs through
/// `handlePositionValuationFailure`.
///
extension GRDBAnalysisRepository {

  /// Loads every investment-like account id. Persisted valuation mode is
  /// intentionally ignored: every account in this bucket uses the position
  /// fold at runtime.
  static func fetchInvestmentAccountIds(database: Database) throws -> Set<UUID> {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT id FROM account
        WHERE type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
        """)
    var ids = Set<UUID>()
    ids.reserveCapacity(rows.count)
    for row in rows {
      if let id: UUID = row["id"] {
        ids.insert(id)
      }
    }
    return ids
  }

  // MARK: - Investment per-day fold

  /// One decoded entry in the investment-position cursor walk — a per-day,
  /// per-account, per-instrument quantity ready to apply to the
  /// cumulative `positions` dict.
  private struct InvestmentPositionEntry {
    let dayKey: Date
    let accountId: UUID
    let instrument: Instrument
    let quantity: Decimal
  }

  /// One day's accumulated investment-position plan: the day key (also the failure
  /// context), the synchronous fast-path subtotal (profile-instrument
  /// positions plus skipped zeros), and the number of foreign-position
  /// conversion requests this day contributed to the flat batch. The
  /// assemble pass slices `requestCount` outcomes back out per day in order.
  private struct InvestmentPositionDayPlan {
    let dayKey: Date
    let fastPathTotal: Decimal
    let requestCount: Int
  }

  /// Per-day position-valuation fold for investment-like accounts. The per-day error
  /// contract: only `CancellationError` throws from `convertResultBatch`
  /// and rethrows immediately; a per-position conversion failure arrives
  /// as a `.failure` outcome in the assemble phase, which drops that day
  /// from `dailyBalances` and logs through `handlePositionValuationFailure`.
  ///
  /// Batched in three phases: (1) walk `dailyBalances.keys.sorted()`,
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
  /// from `dailyBalances` — so cumulative position state stays correct on every
  /// following day.
  ///
  /// `priorRows` and `postRows` carry only rows whose `accountId`
  /// belongs to an investment-like account — pre-filtered in
  /// `readDailyBalancesAggregation` so this fold neither re-checks
  /// membership nor walks rows for accounts it doesn't own.
  static func applyInvestmentPositionValuations(
    priorRows: [DailyBalanceAccountRow],
    postRows: [DailyBalanceAccountRow],
    to dailyBalances: inout [Date: DailyBalance],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws {
    guard !context.investmentAccountIds.isEmpty,
      !dailyBalances.isEmpty
    else { return }

    let (plans, requests) = accumulateInvestmentPositionDays(
      priorRows: priorRows,
      postRows: postRows,
      days: dailyBalances.keys.sorted(),
      context: context)

    // The all-fast-path case produces an empty batch (no `await` inside),
    // so check cancellation explicitly before resolving.
    try Task.checkCancellation()
    let outcomes = try await context.conversionService.convertResultBatch(requests)

    assembleInvestmentPositionDays(
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
  private static func accumulateInvestmentPositionDays(
    priorRows: [DailyBalanceAccountRow],
    postRows: [DailyBalanceAccountRow],
    days: [Date],
    context: DailyBalancesAssemblyContext
  ) -> (plans: [InvestmentPositionDayPlan], requests: [BatchConversionRequest]) {
    var positions = seedPriorInvestmentPositions(
      priorRows: priorRows, instrumentMap: context.instrumentMap)
    let entries = buildInvestmentPositionEntries(
      postRows: postRows, instrumentMap: context.instrumentMap)
    let profileInstrument = context.profileInstrument

    var valueIndex = 0
    var plans: [InvestmentPositionDayPlan] = []
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
        InvestmentPositionDayPlan(
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
  /// `dailyBalances` and logs once via `handlePositionValuationFailure`.
  /// `.knownZero` (e.g. an `.unpriced` / `.spam` crypto position)
  /// contributes zero rather than failing the day — issue #790.
  private static func assembleInvestmentPositionDays(
    plans: [InvestmentPositionDayPlan],
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
        // a gap, matching the historic walk's per-day error contract.
        handlers.handlePositionValuationFailure(failure, plan.dayKey)
        dailyBalances.removeValue(forKey: plan.dayKey)
        continue
      }
      mergeInvestmentPositionTotal(
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
  private static func seedPriorInvestmentPositions(
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
  private static func buildInvestmentPositionEntries(
    postRows: [DailyBalanceAccountRow],
    instrumentMap: [String: Instrument]
  ) -> [InvestmentPositionEntry] {
    var entries: [InvestmentPositionEntry] = []
    entries.reserveCapacity(postRows.count)
    for row in postRows {
      let instrument = resolveInstrument(row.instrumentId, in: instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      entries.append(
        InvestmentPositionEntry(
          dayKey: Calendar.current.startOfDay(for: row.sampleDate),
          accountId: row.accountId,
          instrument: instrument,
          quantity: quantity))
    }
    entries.sort { $0.dayKey < $1.dayKey }
    return entries
  }

  /// Write a per-day position total into the existing
  /// `dailyBalances[dayKey]` row and recompute `netWorth`. No-op when
  /// the day is absent after an earlier conversion failure.
  private static func mergeInvestmentPositionTotal(
    _ total: InstrumentAmount,
    into dailyBalances: inout [Date: DailyBalance],
    on dayKey: Date,
    profileInstrument: Instrument
  ) {
    precondition(
      total.instrument == profileInstrument,
      "mergeInvestmentPositionTotal: total must be in profileInstrument; got \(total.instrument.id)"
    )
    guard let existing = dailyBalances[dayKey] else { return }
    dailyBalances[dayKey] = DailyBalance(
      date: existing.date,
      balance: existing.balance,
      earmarked: existing.earmarked,
      availableFunds: existing.availableFunds,
      investments: existing.investments,
      investmentValue: total,
      netWorth: existing.balance + total,
      bestFit: existing.bestFit,
      isForecast: existing.isForecast)
  }
}
