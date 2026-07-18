import Foundation
import GRDB
import OSLog

/// GRDB-backed implementation of `AnalysisRepository`. Reads the core
/// financial graph (accounts, transactions, and legs)
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
  // `CategoryBalancesFilterArgs`. Same shape as `+ExpenseBreakdown`, but
  // the SQL has no `category_id IS NOT NULL` filter: null-category rows
  // are the "Uncategorised" Reports total, assembled in the same pass as
  // the categorised `CategoryBalances.byCategory` map. There is no
  // GRDB-specific `fetchCategoryBalancesByType` override — the protocol
  // extension's default (two `fetchCategoryBalances` calls) is used as-is.
  //
  // `+IncomeAndExpense.swift` — types (`IncomeAndExpenseRow`,
  // `IncomeAndExpenseAggregation`, `IncomeAndExpenseHandlers`,
  // `IncomeAndExpenseFailureContext`), `assembleIncomeAndExpense`, and
  // private helpers (`convertRowSums`, `makeEmptyMonthBucket`,
  // `applyConvertedRow`, `flattenIncomeAndExpenseBuckets`).
  //
  // `+IncomeAndExpenseAggregation.swift` — `fetchIncomeAndExpenseAggregation`,
  // `mapAggregationRow`, and file-private `incomeAndExpenseAggregationSQL`.
  //
  // `+TaxIncomeExpense.swift` — tax aggregation types, summary SQL, row
  // mapping, conversion planning, and summary assembly.
  //
  // `+TaxIncomeExpenseDetail.swift` — owner/type-scoped tax-detail SQL fetch,
  // row mapping, request construction, and assembly that preserves
  // contributing transaction IDs.
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
  // `+DailyBalancesInvestmentPositions.swift` — `applyInvestmentPositionValuations`
  // fold + its two-phase helpers (`accumulateInvestmentPositionDays` /
  // `assembleInvestmentPositionDays`, around the `InvestmentPositionDayPlan` plan type)
  // and private helpers (`seedPriorInvestmentPositions`,
  // `buildInvestmentPositionEntries`, `mergeInvestmentPositionTotal`,
  // `InvestmentPositionEntry`).
  // Pre-filtered investment rows arrive via the aggregation; the fold
  // computes per-day position valuations and writes
  // `DailyBalance.investmentValue`.
  //
  // `+DailyBalancesForecast.swift` — `generateForecast` plus its
  // private helpers (`preConvertForecastInstances`,
  // `rebuildForecastInstance`, the `ForecastInstancePlan` value type,
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
    let failures = AnalysisConversionFailureCollector()
    defer { logConversionFailures(failures, operation: "fetchDailyBalances") }
    let handlers = DailyBalancesHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchDailyBalances: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        failures.record(error, context: "day=\(context.day)")
      },
      handlePositionValuationFailure: { error, date in
        failures.record(error, context: "investment date=\(date)")
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
    let failures = AnalysisConversionFailureCollector()
    defer { logConversionFailures(failures, operation: "fetchExpenseBreakdown") }
    let handlers = ExpenseBreakdownHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchExpenseBreakdown: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        failures.record(
          error,
          instrumentId: context.instrumentId,
          context: "day=\(context.day) category=\(context.categoryId?.uuidString ?? "nil")")
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
    let failures = AnalysisConversionFailureCollector()
    defer { logConversionFailures(failures, operation: "fetchIncomeAndExpense") }
    let handlers = IncomeAndExpenseHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchIncomeAndExpense: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        failures.record(
          error, instrumentId: context.instrumentId, context: "day=\(context.day)")
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
  ) async throws -> CategoryBalances {
    let args = CategoryBalancesFilterArgs(
      dateRange: dateRange,
      transactionType: transactionType,
      accountId: filters?.accountId,
      earmarkId: filters?.earmarkId,
      payee: filters?.payee,
      categoryIds: filters?.categoryIds ?? [],
      excludesAccountlessUncategorised: filters?.excludesAccountlessUncategorised ?? false)
    // Hoisted ahead of the snapshot for the same cross-database reason
    // as `fetchDailyBalances(after:forecastUntil:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    let aggregation = try await Self.fetchCategoryBalancesAggregation(
      database: database, instruments: instruments, args: args)
    let logger = self.logger
    let failures = AnalysisConversionFailureCollector()
    defer { logConversionFailures(failures, operation: "fetchCategoryBalances") }
    let handlers = CategoryBalancesHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchCategoryBalances: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        failures.record(
          error,
          instrumentId: context.instrumentId,
          context: "day=\(context.day) category=\(context.categoryId?.uuidString ?? "none")")
      })
    return try await Self.assembleCategoryBalances(
      aggregation: aggregation,
      targetInstrument: targetInstrument,
      conversionService: conversionService,
      handlers: handlers)
  }

  func fetchTaxIncomeExpenseSummaries(
    dateInterval: Range<Date>,
    targetInstrument: Instrument,
    defaultTaxOwnerId: UUID
  ) async throws -> [TaxIncomeExpenseSummary] {
    let instruments = try await instrumentResolver.instrumentMap()
    let aggregation = try await Self.fetchTaxIncomeExpenseAggregation(
      database: database,
      instruments: instruments,
      dateInterval: dateInterval,
      defaultTaxOwnerId: defaultTaxOwnerId)
    let logger = self.logger
    let failures = AnalysisConversionFailureCollector()
    defer { logConversionFailures(failures, operation: "fetchTaxIncomeExpenseSummaries") }
    let handlers = TaxIncomeExpenseHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchTaxIncomeExpenseSummaries: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        failures.record(
          error,
          instrumentId: context.instrumentId,
          context:
            "day=\(context.day) owners=\(context.ownerIds.map(\.uuidString).joined(separator: ","))"
        )
      })
    return try await Self.assembleTaxIncomeExpenseSummaries(
      aggregation: aggregation,
      targetInstrument: targetInstrument,
      conversionService: conversionService,
      handlers: handlers)
  }

  func fetchTaxIncomeExpenseDetails(
    dateInterval: Range<Date>,
    targetInstrument: Instrument,
    defaultTaxOwnerId: UUID,
    ownerId: UUID?,
    type: TransactionType
  ) async throws -> [TaxIncomeExpenseDetailRow] {
    let instruments = try await instrumentResolver.instrumentMap()
    let selection = TaxIncomeExpenseDetailSelection(ownerId: ownerId, type: type)
    let aggregation = try await Self.fetchTaxIncomeExpenseDetailAggregation(
      database: database,
      instruments: instruments,
      dateInterval: dateInterval,
      defaultTaxOwnerId: defaultTaxOwnerId,
      selection: selection)
    let logger = self.logger
    let failures = AnalysisConversionFailureCollector()
    defer { logConversionFailures(failures, operation: "fetchTaxIncomeExpenseDetails") }
    let handlers = TaxIncomeExpenseHandlers(
      handleUnparseableDay: { day in
        logger.error(
          "fetchTaxIncomeExpenseDetails: skipping row with unparseable day '\(day)'")
      },
      handleConversionFailure: { error, context in
        failures.record(
          error,
          instrumentId: context.instrumentId,
          context:
            "day=\(context.day) owners=\(context.ownerIds.map(\.uuidString).joined(separator: ","))"
        )
      })
    return try await Self.assembleTaxIncomeExpenseDetails(
      aggregation: aggregation,
      targetInstrument: targetInstrument,
      conversionService: conversionService,
      selection: selection,
      handlers: handlers)
  }
}

extension GRDBAnalysisRepository {
  private func logConversionFailures(
    _ collector: AnalysisConversionFailureCollector,
    operation: String
  ) {
    for summary in collector.summaries() {
      let instrument = summary.instrumentId ?? "unknown"
      let message =
        "\(operation): conversion failed \(summary.count) time(s) for instrument=\(instrument); sample \(summary.sampleContext): \(summary.message)"
      if summary.isTransient {
        logger.warning("\(message, privacy: .public)")
      } else {
        logger.error("\(message, privacy: .public)")
      }
    }
  }
}
