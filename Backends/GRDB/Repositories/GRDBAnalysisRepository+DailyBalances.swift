import Foundation
import GRDB

/// Swift assembly orchestration for `fetchDailyBalances`. Companion files
/// split the workload further:
/// - `+DailyBalancesTypes.swift` holds the row, bundle, handler, and
///   context types shared across the siblings.
/// - `+DailyBalancesAggregation.swift` holds the four SQL fetches.
/// - `+DailyBalancesPrewarm.swift` holds the concurrent conversion
///   pre-warm that runs before the serial walk.
/// - `+DailyBalancesInvestmentValues.swift` holds the per-day
///   recorded-value snapshot fold-in.
/// - `+DailyBalancesTradesMode.swift` holds the per-day trades-mode
///   position-valuation fold-in (sister of the snapshot fold).
/// - `+DailyBalancesForecast.swift` holds the forecast extrapolation.
///
/// Mirrors the `+ExpenseBreakdown.swift`, `+CategoryBalances.swift`,
/// and `+IncomeAndExpense.swift` shapes: static helpers take their
/// dependencies as parameters so this sibling-file extension doesn't
/// reach into the main class's `private` storage.
///
/// Per-day conversion runs in Swift on the day's parsed `Date` so the
/// per-day rate-cache equivalence (Rule 5 of
/// `INSTRUMENT_CONVERSION_GUIDE.md`) holds. Forecast extrapolation
/// runs Swift-side after the historic span and converts on `Date()`
/// (Rule 6) — exchange-rate sources have no future rates, and a single
/// snapshot is the best available estimate.
extension GRDBAnalysisRepository {

  // MARK: - Public assembly entry point

  /// Walks the per-day deltas, mutates a `PositionBook`, calls
  /// `PositionBook.dailyBalance(...)` once per day, then folds in the
  /// investment-value overrides, runs best-fit linear regression, and
  /// generates the forecast tail. Conversion runs outside the
  /// `database.read` closure (in this async helper) so the
  /// `Database` reference stays inside the snapshot.
  ///
  /// Per-day error contract (Rule 11 scoping —
  /// `INSTRUMENT_CONVERSION_GUIDE.md`): when a single day's conversion
  /// fails, the day is *omitted* from the result and
  /// `handleConversionFailure` is invoked with the failing day's
  /// context. The loop continues processing remaining days and the
  /// function returns the partially-populated history rather than
  /// throwing — pinned by
  /// `AnalysisRule11ScopingTests.dailyBalanceConversionFailureIsScopedPerDay`.
  /// A `CancellationError` is rethrown immediately and never folded
  /// into the conversion-failure path.
  ///
  /// **Why the contract differs from the other analysis aggregations.**
  /// Daily balances are rendered as a continuous history line in the
  /// chart UI; throwing on any per-day failure would erase the entire
  /// timeline, including days that *did* convert. Income/expense
  /// breakdowns roll up into per-month buckets where a missing day
  /// silently distorts the bucket — there the rethrow exists as a
  /// loud signal that the bucket is incomplete.
  ///
  /// - Returns: the historic balances followed by the forecast
  ///   balances, ordered by date ascending.
  @concurrent
  static func assembleDailyBalances(
    aggregation: DailyBalancesAggregation,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    handlers: DailyBalancesHandlers
  ) async throws -> [DailyBalance] {
    let context = DailyBalancesAssemblyContext(
      investmentAccountIds: aggregation.investmentAccountIds,
      tradesModeInvestmentAccountIds: aggregation.tradesModeInvestmentAccountIds,
      instrumentMap: aggregation.instrumentMap,
      profileInstrument: profileInstrument,
      conversionService: conversionService)
    var book = seedPriorBook(
      accountRows: aggregation.priorAccountRows,
      earmarkRows: aggregation.priorEarmarkRows,
      context: context)

    var dailyBalances = try await walkDays(
      book: &book,
      accountRows: aggregation.accountRows,
      earmarkRows: aggregation.earmarkRows,
      context: context,
      handlers: handlers)

    try await applyInvestmentValues(
      aggregation.investmentValues,
      to: &dailyBalances,
      context: context,
      handlers: handlers)

    try await applyTradesModePositionValuations(
      priorRows: aggregation.priorTradesModeAccountRows,
      postRows: aggregation.tradesModeAccountRows,
      to: &dailyBalances,
      context: context,
      handlers: handlers)

    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    applyBestFit(to: &actualBalances, instrument: profileInstrument)

    var forecastBalances: [DailyBalance] = []
    if let forecastUntil = aggregation.forecastUntil {
      forecastBalances = try await generateForecast(
        scheduled: aggregation.scheduled,
        startingBook: book,
        endDate: forecastUntil,
        context: context)
    }

    return actualBalances + forecastBalances
  }

  // MARK: - Private helpers

  /// Seed the position book with pre-`after` rows under
  /// `asStartingBalance: true` semantics. Earmark rows use the same
  /// math as the per-leg `apply` would produce (sum quantities into
  /// `earmarks`); account rows feed both `accounts` and (for
  /// investment accounts) `accountsFromTransfers` regardless of leg
  /// type, mirroring the per-leg `asStartingBalance: true` fast path.
  ///
  /// Returns the seeded book directly — pre-`after` deltas are not
  /// emitted as `DailyBalance` rows, so there's no per-day walk on the
  /// seed step.
  private static func seedPriorBook(
    accountRows: [DailyBalanceAccountRow],
    earmarkRows: [DailyBalanceEarmarkRow],
    context: DailyBalancesAssemblyContext
  ) -> PositionBook {
    var book = PositionBook.empty
    for row in accountRows {
      let instrument = resolveInstrument(row.instrumentId, in: context.instrumentMap)
      let quantity = InstrumentAmount(storageValue: row.qty, instrument: instrument).quantity
      book.accounts[row.accountId, default: [:]][instrument, default: 0] += quantity
      if context.investmentAccountIds.contains(row.accountId) {
        // `asStartingBalance: true` — every leg type on an investment
        // account contributes to `accountsFromTransfers` so the
        // post-cutoff `.investmentTransfersOnly` reading rule sees
        // the historical position as a baseline.
        book.accountsFromTransfers[
          row.accountId, default: [:]][instrument, default: 0] += quantity
      }
    }
    for row in earmarkRows {
      let instrument = resolveInstrument(row.instrumentId, in: context.instrumentMap)
      let quantity = InstrumentAmount(storageValue: row.qty, instrument: instrument).quantity
      book.earmarks[row.earmarkId, default: [:]][instrument, default: 0] += quantity
    }
    return book
  }

  /// Walk the post-`after` rows in day order; for each day, apply
  /// every account / earmark delta then call
  /// `PositionBook.dailyBalance(...)` once. The book mutates in place
  /// so balances are cumulative — same shape as the per-leg walker.
  ///
  /// Days are keyed by the row group's `sample_date` instant
  /// (typically the earliest `t.date` inside the SQL group) rather
  /// than the UTC day-string, so the resulting `DailyBalance.date`
  /// preserves the *local* calendar-day semantics required by the
  /// per-method contract tests. UTC-day grouping in SQL is purely an
  /// indexing artefact — at TZ boundaries two UTC-day groups can map
  /// to the same local day, in which case the dictionary entry is
  /// overwritten cumulatively (the book mutates in order across both
  /// groups, so the final entry reflects every leg).
  ///
  /// Per-day conversion failures invoke `handleConversionFailure` and
  /// drop only that day from the returned dictionary — the loop
  /// continues so sibling days still render. See
  /// `assembleDailyBalances` for the full Rule 11 contract.
  private static func walkDays(
    book: inout PositionBook,
    accountRows: [DailyBalanceAccountRow],
    earmarkRows: [DailyBalanceEarmarkRow],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws -> [Date: DailyBalance] {
    let accountByDay = Dictionary(grouping: accountRows, by: \.day)
    let earmarkByDay = Dictionary(grouping: earmarkRows, by: \.day)
    let allDayStrings = Set(accountByDay.keys).union(earmarkByDay.keys).sorted()
    // Trades-mode accounts contribute to investmentValue via
    // applyTradesModePositionValuations, not to bankTotal. Including
    // them in BalanceContext.investmentAccountIds excludes them from
    // PositionBook.dailyBalance's `for ... where !investmentAccountIds`
    // sum (no double-count) without changing accountsFromTransfers
    // membership (which seedPriorBook / applyDailyDeltas gate on the
    // recorded-value-only set, so the .investmentTransfersOnly read
    // continues to see only recorded-value transfer cash).
    let allInvestmentIds =
      context.investmentAccountIds.union(context.tradesModeInvestmentAccountIds)
    let balanceContext = PositionBook.BalanceContext(
      investmentAccountIds: allInvestmentIds,
      profileInstrument: context.profileInstrument,
      rule: .investmentTransfersOnly,
      conversionService: context.conversionService)
    var dailyBalances: [Date: DailyBalance] = [:]
    for dayString in allDayStrings {
      let accountSlice = accountByDay[dayString] ?? []
      let earmarkSlice = earmarkByDay[dayString] ?? []
      // Pick a representative instant from whichever slice has rows.
      // SQL's `MIN(t.date)` populates `sampleDate` per row; the value
      // is identical across rows of the same SQL group up to the
      // group key's resolution.
      let sample =
        accountSlice.first.map(\.sampleDate)
        ?? earmarkSlice.first.map(\.sampleDate)
      guard let sample else {
        // Every group's rows carry a sampleDate via SQL `MIN(t.date)`,
        // so this branch only fires if both slices are empty for a
        // day-string we discovered above — which is structurally
        // impossible given the union construction. Surface it
        // through the unparseable-day callback to preserve the
        // diagnostic path.
        handlers.handleUnparseableDay(dayString)
        continue
      }
      applyDailyDeltas(
        accountRows: accountSlice,
        earmarkRows: earmarkSlice,
        context: context,
        into: &book)
      let dayKey = Calendar.current.startOfDay(for: sample)
      do {
        dailyBalances[dayKey] = try await book.dailyBalance(
          on: sample, context: balanceContext, isForecast: false)
      } catch let cancel as CancellationError {
        // Cooperative cancellation surfaces unchanged — never folded
        // into the per-day conversion-failure log path.
        throw cancel
      } catch {
        let failureContext = DailyBalancesFailureContext(day: dayString)
        handlers.handleConversionFailure(error, failureContext)
        continue
      }
    }
    return dailyBalances
  }

  /// Apply one day's account and earmark deltas to the in-place
  /// `PositionBook`. Account rows update `accounts` and (for transfer
  /// legs into investment accounts) `accountsFromTransfers`; earmark
  /// rows update `earmarks`. Saved/spent earmark dicts are NOT touched
  /// — `PositionBook.dailyBalance(...)` reads only `earmarks` for the
  /// `earmarked` sum, so writing them would be wasted work.
  private static func applyDailyDeltas(
    accountRows: [DailyBalanceAccountRow],
    earmarkRows: [DailyBalanceEarmarkRow],
    context: DailyBalancesAssemblyContext,
    into book: inout PositionBook
  ) {
    for row in accountRows {
      let instrument = resolveInstrument(row.instrumentId, in: context.instrumentMap)
      let quantity = InstrumentAmount(storageValue: row.qty, instrument: instrument).quantity
      book.accounts[row.accountId, default: [:]][instrument, default: 0] += quantity
      if context.investmentAccountIds.contains(row.accountId), row.type == "transfer" {
        book.accountsFromTransfers[
          row.accountId, default: [:]][instrument, default: 0] += quantity
      }
    }
    for row in earmarkRows {
      let instrument = resolveInstrument(row.instrumentId, in: context.instrumentMap)
      let quantity = InstrumentAmount(storageValue: row.qty, instrument: instrument).quantity
      book.earmarks[row.earmarkId, default: [:]][instrument, default: 0] += quantity
    }
  }

  /// Reconstruct an `Instrument` value from the row's `instrument_id`
  /// string, falling back to ambient fiat when the registry has no
  /// stored row for the id. Mirrors the same lookup used by the other
  /// SQL aggregations. Internal so sibling `+DailyBalances*.swift`
  /// extensions can share one decoding helper.
  static func resolveInstrument(
    _ id: String, in map: [String: Instrument]
  ) -> Instrument {
    map[id] ?? Instrument.fiat(code: id)
  }
}
