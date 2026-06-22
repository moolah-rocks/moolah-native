import Foundation
import OSLog

/// Forecast extrapolation for `fetchDailyBalances`. Scheduled
/// transactions are expanded into per-instance `Transaction` values
/// in Swift (SQL can't extrapolate recurring patterns), each
/// instance's foreign-instrument legs are pre-converted on `Date()`
/// (Rule 6 of `INSTRUMENT_CONVERSION_GUIDE.md` — exchange-rate
/// sources have no future rates), and the converted instances feed a
/// sequential `PositionBook` walk that emits one forecast
/// `DailyBalance` per instance day.
extension GRDBAnalysisRepository {
  /// Generate the forecast tail by extrapolating scheduled
  /// transactions and feeding each instance into a fresh
  /// `PositionBook` walk. The forecast path stays Swift-only because
  /// SQL can't extrapolate recurring patterns. Conversion runs on
  /// `Date()` because exchange-rate sources have no future rates.
  static func generateForecast(
    scheduled: [Transaction],
    startingBook: PositionBook,
    endDate: Date,
    context: DailyBalancesAssemblyContext
  ) async throws -> [DailyBalance] {
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(
        contentsOf: extrapolateScheduledTransaction(scheduledTxn, until: endDate))
    }
    instances.sort { $0.date < $1.date }
    // Scheduled transactions live in the future; exchange-rate sources
    // can't return future rates. Use today's rate as the best
    // available estimate, captured once so every instance uses the
    // same snapshot (Rule 6 of `INSTRUMENT_CONVERSION_GUIDE.md`).
    let conversionDate = Date()
    let converted = try await preConvertForecastInstances(
      instances,
      profileInstrument: context.profileInstrument,
      conversionService: context.conversionService,
      on: conversionDate)
    return try await runForecastAccumulator(
      converted: converted,
      startingBook: startingBook,
      context: context)
  }

  /// One instance's slot in the flat batch request list: the range of
  /// requests that belong to its foreign-instrument legs, index-aligned
  /// to `legs` so the rebuild can stitch converted quantities back in.
  /// Same-instrument legs carry no request (they pass through untouched),
  /// so `legRequestIndices` maps each leg to its request index or `nil`.
  private struct ForecastInstancePlan {
    let instance: Transaction
    /// For each leg, the index into the flat batch (and thus the flat
    /// outcomes list) that converts it, or `nil` when the leg already
    /// shares the profile instrument and needs no conversion.
    let legRequestIndices: [Int?]
    /// `true` when at least one leg needs conversion. Instances with no
    /// foreign leg pass straight through, mirroring the same-instrument
    /// fast-path guard the serial per-leg conversion used.
    let needsConversion: Bool
  }

  /// Pre-convert all instances in a single batch — each leg conversion is
  /// independent, so they collapse into one `convertResultBatch(...)` hop
  /// over the profile instrument on `conversionDate`. The accumulator that
  /// follows is inherently sequential (each iteration depends on the
  /// previous running totals), so it can't be parallelised.
  ///
  /// Per-instance error tolerance (Rule 11,
  /// `INSTRUMENT_CONVERSION_GUIDE.md`): a single instance's conversion
  /// failure must not abort the whole forecast (that surfaced on the
  /// Analysis page as a full-screen "WalletSyncError"). When ANY of an
  /// instance's leg conversions resolves to `.failure`, the instance is
  /// passed through *unconverted* and logged — the accumulator's per-day
  /// `catch` then drops that day, and every later occurrence of an
  /// unpriceable recurring leg drops the same way, so a day's total is
  /// never partial. `.knownZero` legs fold to a zero-quantity leg (issue
  /// #790).
  ///
  /// Cancellation propagates as a thrown `CancellationError`.
  private static func preConvertForecastInstances(
    _ instances: [Transaction],
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    on conversionDate: Date
  ) async throws -> [Transaction] {
    guard !instances.isEmpty else { return [] }

    // Phase 1 — plan: collect every foreign leg's request across all
    // instances into one flat list, recording per-leg request indices so
    // the rebuild can stitch outcomes back in.
    var requests: [BatchConversionRequest] = []
    var plans: [ForecastInstancePlan] = []
    plans.reserveCapacity(instances.count)
    for instance in instances {
      var legRequestIndices: [Int?] = []
      legRequestIndices.reserveCapacity(instance.legs.count)
      var needsConversion = false
      for leg in instance.legs {
        if leg.instrument.id == profileInstrument.id {
          legRequestIndices.append(nil)
        } else {
          needsConversion = true
          legRequestIndices.append(requests.count)
          requests.append(
            BatchConversionRequest(
              amount: InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument),
              target: profileInstrument,
              date: conversionDate))
        }
      }
      plans.append(
        ForecastInstancePlan(
          instance: instance,
          legRequestIndices: legRequestIndices,
          needsConversion: needsConversion))
    }

    // Phase 2 — one batched conversion. Cancellation throws here.
    let outcomes = try await conversionService.convertResultBatch(requests)

    // Phase 3 — rebuild each instance from its outcome slice, passing the
    // instance through unconverted if any of its legs failed (Rule 11).
    return plans.enumerated().map { index, plan in
      rebuildForecastInstance(
        plan,
        outcomes: outcomes,
        profileInstrument: profileInstrument,
        instanceIndex: index)
    }
  }

  /// Rebuild a single forecast instance from the flat `outcomes` list using
  /// its `legRequestIndices`. Same-instrument legs (`nil` index) pass
  /// through; `.value` legs adopt the converted quantity in the profile
  /// instrument; `.knownZero` legs fold to a zero-quantity profile leg; a
  /// `.failure` on any leg passes the WHOLE instance through unconverted and
  /// logs once (per-instance error tolerance, Rule 11).
  private static func rebuildForecastInstance(
    _ plan: ForecastInstancePlan,
    outcomes: [BatchConversionOutcome],
    profileInstrument: Instrument,
    instanceIndex: Int
  ) -> Transaction {
    guard plan.needsConversion else { return plan.instance }
    var convertedLegs: [TransactionLeg] = []
    convertedLegs.reserveCapacity(plan.instance.legs.count)
    for (leg, requestIndex) in zip(plan.instance.legs, plan.legRequestIndices) {
      guard let requestIndex else {
        convertedLegs.append(leg)
        continue
      }
      let convertedQty: Decimal
      switch outcomes[requestIndex] {
      case .value(let amount):
        convertedQty = amount.quantity
      case .knownZero:
        convertedQty = 0
      case .failure(let error):
        forecastLogger.warning(
          """
          Forecast pre-conversion failed for instance \(instanceIndex, privacy: .public) — \
          \(error.localizedDescription, privacy: .public). Passing it through \
          unconverted; affected forecast days drop (Rule 11).
          """)
        return plan.instance
      }
      convertedLegs.append(
        TransactionLeg(
          accountId: leg.accountId,
          instrument: profileInstrument,
          quantity: convertedQty,
          type: leg.type,
          categoryId: leg.categoryId,
          earmarkId: leg.earmarkId))
    }
    var result = plan.instance
    result.legs = convertedLegs
    return result
  }

  // MARK: - Scheduled-transaction extrapolation

  /// Expand a single scheduled transaction into a flat list of dated
  /// instances up to `endDate`. Non-recurring entries pass through
  /// unchanged (or drop out when their date is past `endDate`); each
  /// returned instance has its `recurPeriod` / `recurEvery` cleared so
  /// downstream consumers see plain dated transactions.
  static func extrapolateScheduledTransaction(
    _ scheduled: Transaction,
    until endDate: Date
  ) -> [Transaction] {
    guard let period = scheduled.recurPeriod, period != .once else {
      return scheduled.date <= endDate ? [scheduled] : []
    }

    let every = scheduled.recurEvery ?? 1
    var instances: [Transaction] = []
    var currentDate = scheduled.date

    while currentDate <= endDate {
      var instance = scheduled
      instance.date = currentDate
      instance.recurPeriod = nil
      instance.recurEvery = nil
      instances.append(instance)

      guard let next = nextDueDate(from: currentDate, period: period, every: every) else {
        break
      }
      currentDate = next
    }

    return instances
  }

  /// Compute the next due date for a recurring schedule. Returns `nil`
  /// when the period is `.once` (callers treat that as "no further
  /// instances") or when `Calendar.date(byAdding:to:)` declines to
  /// produce a date.
  static func nextDueDate(from date: Date, period: RecurPeriod, every: Int) -> Date? {
    let calendar = Calendar.current
    var components = DateComponents()

    switch period {
    case .day:
      components.day = every
    case .week:
      components.weekOfYear = every
    case .month:
      components.month = every
    case .year:
      components.year = every
    case .once:
      return nil
    }

    return calendar.date(byAdding: components, to: date)
  }

  /// Walk the pre-converted instances and emit one `DailyBalance` per
  /// instance day. Same Rule 11 scoping as the historic walk: a single
  /// day's conversion failure must not drop sibling forecast days.
  private static func runForecastAccumulator(
    converted: [Transaction],
    startingBook: PositionBook,
    context: DailyBalancesAssemblyContext
  ) async throws -> [DailyBalance] {
    var book = startingBook
    var forecastBalances: [Date: DailyBalance] = [:]
    // Trades-mode accounts contribute to investmentValue via the
    // historic per-day fold; forecast days don't get a trades-mode
    // contribution and would otherwise sum the raw quantity into
    // `balance`. Including the trades-mode set in
    // BalanceContext.investmentAccountIds excludes those accounts
    // from PositionBook.dailyBalance's bankTotal sum. The second use
    // of context.investmentAccountIds below (book.apply) is left
    // unchanged — it gates accountsFromTransfers membership and must
    // stay recorded-value-only.
    let allInvestmentIds =
      context.investmentAccountIds.union(context.tradesModeInvestmentAccountIds)
    let balanceContext = PositionBook.BalanceContext(
      investmentAccountIds: allInvestmentIds,
      profileInstrument: context.profileInstrument,
      rule: .investmentTransfersOnly,
      conversionService: context.conversionService)
    for instance in converted {
      book.apply(instance, investmentAccountIds: context.investmentAccountIds)
      let dayKey = Calendar.current.startOfDay(for: instance.date)
      do {
        forecastBalances[dayKey] = try await book.dailyBalance(
          on: instance.date, context: balanceContext, isForecast: true)
      } catch let cancel as CancellationError {
        // Cooperative cancellation surfaces unchanged — never folded
        // into the per-day conversion-failure log path.
        throw cancel
      } catch {
        forecastLogger.warning(
          """
          Skipping forecast balance for \(dayKey, privacy: .public) — \
          conversion failed: \(error.localizedDescription, privacy: .public). \
          Sibling forecast days continue to render.
          """
        )
      }
    }
    return forecastBalances.values.sorted { $0.date < $1.date }
  }
}

/// File-private logger for forecast warnings emitted from the
/// accumulator. Hoisted to file scope (rather than reaching for the
/// main class's `private let logger`) so the static helpers stay free
/// of stored-property coupling — same shape as the warnings emitted
/// by other SQL-rewrite extensions.
private let forecastLogger = Logger(
  subsystem: "com.moolah.app", category: "GRDBAnalysisRepository.Forecast")
