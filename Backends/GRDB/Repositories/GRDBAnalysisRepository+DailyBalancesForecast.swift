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

  /// Pre-convert all instances concurrently — each conversion is
  /// independent. The accumulator that follows is inherently
  /// sequential (each iteration depends on the previous running
  /// totals), so it can't be parallelised.
  private static func preConvertForecastInstances(
    _ instances: [Transaction],
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    on conversionDate: Date
  ) async throws -> [Transaction] {
    guard let firstInstance = instances.first else { return [] }
    return try await withThrowingTaskGroup(of: (Int, Transaction).self) { group in
      for (index, instance) in instances.enumerated() {
        group.addTask {
          do {
            let txn = try await convertLegsToProfileInstrument(
              instance,
              to: profileInstrument,
              on: conversionDate,
              conversionService: conversionService)
            return (index, txn)
          } catch let cancel as CancellationError {
            // Cooperative cancellation surfaces unchanged — never
            // folded into the per-day degradation path.
            throw cancel
          } catch {
            // Rule 11 (`INSTRUMENT_CONVERSION_GUIDE.md`): a single
            // instance's conversion failure must not abort the whole
            // forecast (that surfaced on the Analysis page as a
            // full-screen "WalletSyncError"). Pass the instance through
            // *unconverted* and log here — the accumulator's per-day
            // `catch` then drops that day, and every later occurrence
            // of an unpriceable recurring leg drops the same way, so a
            // day's total is never partial. Logging at the point of
            // failure is required: the accumulator only logs if
            // `dailyBalance` itself subsequently throws, which is not
            // guaranteed for every degraded instance.
            forecastLogger.warning(
              """
              Forecast pre-conversion failed for instance \(index, privacy: .public) — \
              \(error.localizedDescription, privacy: .public). Passing it through \
              unconverted; affected forecast days drop (Rule 11).
              """)
            return (index, instance)
          }
        }
      }
      var out = Array(repeating: firstInstance, count: instances.count)
      for try await (index, txn) in group { out[index] = txn }
      return out
    }
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

  // MARK: - Per-instance leg conversion

  /// Return a copy of the transaction with every leg's
  /// quantity/instrument rewritten into the profile instrument. Used
  /// before feeding scheduled-transaction instances into the forecast
  /// accumulator so every leg already shares the profile instrument
  /// when `PositionBook.dailyBalance` is queried (skipping the
  /// multi-instrument conversion path on every forecast day).
  ///
  /// - Parameter date: date passed to the conversion service. For
  ///   forecast use this is `Date()` — the current rate — because
  ///   scheduled transactions have future dates and no exchange-rate
  ///   source has future rates. Same-instrument legs are returned
  ///   untouched.
  static func convertLegsToProfileInstrument(
    _ txn: Transaction,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> Transaction {
    guard txn.legs.contains(where: { $0.instrument.id != instrument.id }) else {
      return txn
    }
    var convertedLegs: [TransactionLeg] = []
    convertedLegs.reserveCapacity(txn.legs.count)
    for leg in txn.legs {
      if leg.instrument.id == instrument.id {
        convertedLegs.append(leg)
        continue
      }
      // `.knownZero` source legs (`.unpriced` / `.spam` crypto) fold to
      // a zero-quantity leg rather than aborting the forecast day —
      // issue #790. Real provider errors still throw so a transient
      // rate failure preserves Rule 11 (mark the day unavailable).
      let conversionResult = try await conversionService.convertResult(
        InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument),
        to: instrument,
        on: date)
      let convertedQty: Decimal
      switch conversionResult {
      case .value(let amount): convertedQty = amount.quantity
      case .knownZero: convertedQty = 0
      }
      convertedLegs.append(
        TransactionLeg(
          accountId: leg.accountId,
          instrument: instrument,
          quantity: convertedQty,
          type: leg.type,
          categoryId: leg.categoryId,
          earmarkId: leg.earmarkId
        ))
    }
    var result = txn
    result.legs = convertedLegs
    return result
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
