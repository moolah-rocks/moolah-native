import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `AnalysisRepository`. Reads the core
/// financial graph (accounts, transactions, legs, investment values)
/// from `data.sqlite`. Every method drives a SQL aggregation that
/// pushes the per-(day, dimension) GROUP BY into SQLite and converts
/// the summed rows in Swift on each row's own day — preserving the
/// per-day rate-cache equivalence required by Rule 5 of
/// `INSTRUMENT_CONVERSION_GUIDE.md`.
///
/// **Concurrency.** `final class` + `@unchecked Sendable` rather than
/// `actor`. All stored properties are `let`. `database`
/// (`any DatabaseWriter`) is `Sendable` (GRDB protocol guarantee — the
/// queue's serial executor mediates concurrent access).
/// `conversionService` is itself `Sendable`. `logger` is `OSLog.Logger`,
/// also `Sendable` (Apple-documented thread-safe value type). Nothing
/// mutates post-init, so the reference can be shared across actor
/// boundaries without a data race.
final class GRDBAnalysisRepository: AnalysisRepository, @unchecked Sendable {
  // MARK: - Cross-extension internals
  // The following are stored / static state shared with sibling-file
  // extensions:
  //
  // `+Conversion.swift` — `parseDayString`, `financialMonth`,
  // `convertedQuantity`. Free of stored-state coupling; takes its
  // dependencies as parameters.
  //
  // `+ExpenseBreakdown.swift` — `fetchExpenseBreakdownAggregation`,
  // `assembleExpenseBreakdown`, `ExpenseBreakdownRow`,
  // `ExpenseBreakdownAggregation`, `ExpenseBreakdownHandlers`. Also
  // free of stored-state coupling.
  //
  // `+CategoryBalances.swift` — `fetchCategoryBalancesAggregation`,
  // `assembleCategoryBalances`, `CategoryBalancesRow`,
  // `CategoryBalancesAggregation`, `CategoryBalancesHandlers`,
  // `CategoryBalancesFilterArgs`. Same shape as `+ExpenseBreakdown`.
  //
  // `+IncomeAndExpense.swift` — types (`IncomeAndExpenseRow`,
  // `IncomeAndExpenseAggregation`, `IncomeAndExpenseHandlers`,
  // `IncomeAndExpenseFailureContext`), `assembleIncomeAndExpense`, and
  // private helpers (`convertRowSums`, `makeEmptyMonthBucket`,
  // `applyConvertedRow`, `flattenIncomeAndExpenseBuckets`).
  //
  // `+IncomeAndExpenseAggregation.swift` — `fetchIncomeAndExpenseAggregation`,
  // `mapAggregationRow`, file-private `incomeAndExpenseAggregationSQL`.
  //
  // `+DailyBalances.swift` — types (`DailyBalanceAccountRow`,
  // `DailyBalanceEarmarkRow`, `DailyBalancesAggregation`,
  // `DailyBalancesFailureContext`, `DailyBalancesHandlers`,
  // `DailyBalancesAssemblyContext`), `assembleDailyBalances`, and
  // private helpers (`seedPriorBook`, `walkDays`, `applyDailyDeltas`,
  // `resolveInstrument`).
  //
  // `+DailyBalancesAggregation.swift` — `fetchDailyBalancesAggregation`,
  // private SQL fetch helpers (`fetchAccountDeltaRowsPostCutoff` /
  // `fetchAccountDeltaRowsPreCutoff`, `fetchEarmarkDeltaRowsPostCutoff` /
  // `fetchEarmarkDeltaRowsPreCutoff`, `fetchScheduledTransactions`,
  // `fetchPriorDeltaRows`, `readDailyBalancesAggregation`), and the
  // shared row-decoder helpers (`decodeAccountDeltaRows`,
  // `decodeEarmarkDeltaRows`).
  //
  // `+DailyBalancesInvestmentValues.swift` — `applyInvestmentValues`
  // plus its private cursor helpers (`advanceInvestmentCursor`,
  // `sumInvestmentValues`); also owns the SQL fetches that produce
  // its inputs (`fetchInvestmentAccountIds`,
  // `fetchInvestmentValueSnapshots`,
  // `fetchTradesModeInvestmentAccountIds`).
  //
  // `+DailyBalancesTradesMode.swift` — `applyTradesModePositionValuations`
  // fold + private helpers (`seedTradesModePriorPositions`,
  // `buildTradesModeEntries`, `mergeTradesModeTotal`,
  // `sumTradesModePositions`, `TradesModePositionEntry`).
  // Pre-filtered trades-mode rows arrive via the aggregation; the fold
  // computes per-day position valuations and adds them onto
  // `DailyBalance.investmentValue`.
  //
  // `+DailyBalancesForecast.swift` — `generateForecast` plus its
  // private helpers (`preConvertForecastInstances`,
  // `runForecastAccumulator`) and a file-private logger for forecast
  // warnings.
  //
  // `database` and `logger` are read by `fetchExpenseBreakdown`,
  // `fetchCategoryBalances`, `fetchIncomeAndExpense`, and
  // `fetchDailyBalances` here in the main file; the sibling extensions
  // pull them through the call site rather than reaching into
  // `private` storage from another file.
  private let database: any DatabaseWriter
  private let instrument: Instrument
  private let conversionService: any InstrumentConversionService
  /// Resolves the `[String: Instrument]` lookup table from the
  /// canonical instrument registry. Fetched once per aggregation
  /// *before* the per-profile `database.read` snapshot opens — the
  /// registry lives on a separate (profile-index) database, so a
  /// cross-database transaction is impossible. Instrument identity is
  /// immutable lookup data; a read that is not atomic with the
  /// aggregation snapshot is safe and intended. Every caller —
  /// production, preview, test, and the sync apply path — injects the
  /// shared `GRDBInstrumentRegistryRepository`; nothing reads the
  /// per-profile `instrument` table `v10_drop_shared_instrument_legacy`
  /// removed. Mirrors `GRDBTransactionRepository`.
  private let instrumentResolver: any InstrumentMapResolving
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "GRDBAnalysisRepository")

  init(
    database: any DatabaseWriter,
    instrument: Instrument,
    conversionService: any InstrumentConversionService,
    instrumentResolver: any InstrumentMapResolving
  ) {
    self.database = database
    self.instrument = instrument
    self.conversionService = conversionService
    self.instrumentResolver = instrumentResolver
  }

  // MARK: - AnalysisRepository conformance

  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    async let balances = fetchDailyBalances(
      after: historyAfter, forecastUntil: forecastUntil)
    async let breakdown = fetchExpenseBreakdown(monthEnd: monthEnd, after: historyAfter)
    async let income = fetchIncomeAndExpense(monthEnd: monthEnd, after: historyAfter)

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income)
  }

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    // Resolve the instrument lookup table before opening the
    // per-profile snapshot: the canonical registry is a separate
    // database, so the map cannot be joined into this transaction.
    // Instrument identity is immutable lookup data — a read not atomic
    // with the aggregation snapshot is safe and intended. Mirrors
    // `GRDBTransactionRepository.fetchAll(filter:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    let aggregation = try await Self.fetchDailyBalancesAggregation(
      database: database,
      instruments: instruments,
      after: after,
      forecastUntil: forecastUntil)
    let logger = self.logger
    let handlers = DailyBalancesHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchDailyBalances: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        // Per-day failures surface as warnings (not errors) — Rule 11
        // scoping treats a single missing day as a recoverable
        // condition: the chart still renders the surrounding days.
        logger.warning(
          """
          fetchDailyBalances: skipping day=\(context.day, privacy: .public) — \
          conversion failed: \
          \(error.localizedDescription, privacy: .public). \
          Sibling days continue to render.
          """)
      },
      handleInvestmentValueFailure: { error, date in
        logger.warning(
          """
          fetchDailyBalances: investment-value conversion failed for \
          date=\(date, privacy: .public): \
          \(error.localizedDescription, privacy: .public). \
          Sibling days continue to render.
          """)
      })
    return try await Self.assembleDailyBalances(
      aggregation: aggregation,
      profileInstrument: instrument,
      conversionService: conversionService,
      handlers: handlers)
  }

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    // Hoisted ahead of the snapshot for the same cross-database reason
    // as `fetchDailyBalances(after:forecastUntil:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    let aggregation = try await Self.fetchExpenseBreakdownAggregation(
      database: database, instruments: instruments, after: after)
    let logger = self.logger
    let handlers = ExpenseBreakdownHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchExpenseBreakdown: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        logger.error(
          """
          fetchExpenseBreakdown: conversion failed for day=\(context.day, privacy: .public) \
          category=\(context.categoryId?.uuidString ?? "nil", privacy: .public) \
          instrument=\(context.instrumentId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      })
    return try await Self.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: instrument,
      conversionService: conversionService,
      monthEnd: monthEnd,
      handlers: handlers)
  }

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    // Hoisted ahead of the snapshot for the same cross-database reason
    // as `fetchDailyBalances(after:forecastUntil:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    let aggregation = try await Self.fetchIncomeAndExpenseAggregation(
      database: database, instruments: instruments, after: after)
    let logger = self.logger
    let handlers = IncomeAndExpenseHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchIncomeAndExpense: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        logger.error(
          """
          fetchIncomeAndExpense: conversion failed for day=\(context.day, privacy: .public) \
          instrument=\(context.instrumentId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      })
    return try await Self.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: instrument,
      conversionService: conversionService,
      monthEnd: monthEnd,
      handlers: handlers)
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount] {
    let args = CategoryBalancesFilterArgs(
      dateRange: dateRange,
      transactionType: transactionType,
      accountId: filters?.accountId,
      earmarkId: filters?.earmarkId,
      payee: filters?.payee,
      categoryIds: filters?.categoryIds ?? [])
    // Hoisted ahead of the snapshot for the same cross-database reason
    // as `fetchDailyBalances(after:forecastUntil:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    let aggregation = try await Self.fetchCategoryBalancesAggregation(
      database: database, instruments: instruments, args: args)
    let logger = self.logger
    let handlers = CategoryBalancesHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchCategoryBalances: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        logger.error(
          """
          fetchCategoryBalances: conversion failed for day=\(context.day, privacy: .public) \
          category=\(context.categoryId, privacy: .public) \
          instrument=\(context.instrumentId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      })
    return try await Self.assembleCategoryBalances(
      aggregation: aggregation,
      targetInstrument: targetInstrument,
      conversionService: conversionService,
      handlers: handlers)
  }
}
