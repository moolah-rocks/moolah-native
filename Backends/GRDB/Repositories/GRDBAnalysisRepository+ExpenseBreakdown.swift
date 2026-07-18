import Foundation
import GRDB

/// SQL aggregation + Swift assembly helpers for `fetchExpenseBreakdown`.
///
/// Mirrors the `GRDBAccountRepository+Positions.swift` shape: every
/// helper is `static` and takes its dependencies (database,
/// instruments, conversion service) as parameters so this sibling-file
/// extension doesn't reach into the main class's `private` stored
/// properties.
extension GRDBAnalysisRepository {
  /// One row of the SQL aggregation that drives `fetchExpenseBreakdown`.
  /// `day` is the ISO-8601 `YYYY-MM-DD` string returned by `DATE(t.date)`
  /// — parsed in Swift on the way out of the read closure so the
  /// `Database` reference doesn't escape into the conversion service.
  struct ExpenseBreakdownRow: Sendable {
    let day: String
    let categoryId: UUID?
    let instrumentId: String
    let qty: Int64
  }

  /// Pair of SQL output rows and the instrument lookup. The lookup is
  /// resolved via the injected `InstrumentMapResolving` *before* the
  /// per-profile read snapshot opens (the canonical registry is a
  /// separate database, so it can't be joined into this transaction);
  /// the SQL rows come from the snapshot. Instrument identity is
  /// immutable lookup data, so the non-atomic pairing is safe and
  /// intended. Mirrors `GRDBTransactionRepository`'s hoisted-map shape.
  struct ExpenseBreakdownAggregation: Sendable {
    let rows: [ExpenseBreakdownRow]
    let instrumentMap: [String: Instrument]
  }

  /// Diagnostic context passed to the conversion-failure handler so the
  /// caller's logger can identify which `(day, category, instrument)`
  /// tuple failed without coupling this helper to a `Logger` instance.
  struct ConversionFailureContext: Sendable {
    let day: String
    let categoryId: UUID?
    let instrumentId: String
  }

  /// Bundle of per-row diagnostic callbacks used by
  /// `assembleExpenseBreakdown`, so its signature takes one parameter
  /// instead of several and other analysis methods can share the same
  /// handler shape.
  struct ExpenseBreakdownHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, ConversionFailureContext) -> Void
  }

  /// Runs the per-(day, category, instrument) SUM(quantity) aggregation
  /// pinned by
  /// `AnalysisAggregationPlanPinningTests.fetchExpenseBreakdownUsesCategoryCoveringIndex`.
  /// The shape — `JOIN "transaction"`, `recur_period IS NULL`,
  /// `type = 'expense'`, `category_id IS NOT NULL`, optional `:after` —
  /// is what selects the `leg_analysis_by_type_category` covering
  /// composite (v3 schema). Any shape drift will trip the plan-pinning
  /// test.
  ///
  /// `account_id` is intentionally NOT in the WHERE clause:
  /// 1. **Semantic contract.** The expense breakdown only filters on
  ///    `leg.type == .expense && leg.categoryId != nil`, so
  ///    categorised expense legs without an account must appear in
  ///    the breakdown. Adding `account_id IS NOT NULL` here would
  ///    silently drop them. Pinned by
  ///    `GRDBExpenseBreakdownConversionTests`.
  /// 2. **Covering index.** `account_id` is not in
  ///    `leg_analysis_by_type_category`'s column list, so adding the
  ///    predicate forces SQLite to fetch the base row and breaks the
  ///    covering property — the plan flips from
  ///    `USING COVERING INDEX` to plain `USING INDEX`.
  static func fetchExpenseBreakdownAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    after: Date?
  ) async throws -> ExpenseBreakdownAggregation {
    try await database.read { database -> ExpenseBreakdownAggregation in
      let sql = """
        SELECT DATE(t.date)        AS day,
               leg.category_id     AS category_id,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type = 'expense'
          AND leg.category_id IS NOT NULL
          AND (:after IS NULL OR t.date >= :after)
        GROUP BY day, category_id, instrument_id
        ORDER BY day ASC, category_id ASC
        """
      let arguments: StatementArguments = ["after": after]
      let sqlRows = try Row.fetchAll(database, sql: sql, arguments: arguments)
      var rows: [ExpenseBreakdownRow] = []
      rows.reserveCapacity(sqlRows.count)
      for row in sqlRows {
        guard let day: String = row["day"] else { continue }
        guard let instrumentId: String = row["instrument_id"] else { continue }
        guard let qty: Int64 = row["qty"] else { continue }
        let categoryId: UUID? = row["category_id"]
        rows.append(
          ExpenseBreakdownRow(
            day: day, categoryId: categoryId, instrumentId: instrumentId, qty: qty))
      }
      return ExpenseBreakdownAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  /// One parseable row paired with its parsed day, retained so the batch
  /// outcome can rebuild its bucket (the day picks the financial month)
  /// and failure context.
  private struct ExpenseBreakdownParsedRow {
    let row: ExpenseBreakdownRow
    let day: Date
  }

  /// One parseable row's conversion plan: the parsed rows, the
  /// index-aligned flat request list, and the day-strings that failed to
  /// parse so the caller surfaces them before the batch.
  private struct ExpenseBreakdownPlan {
    let parsedRows: [ExpenseBreakdownParsedRow]
    let requests: [BatchConversionRequest]
    let unparseableDays: [String]
  }

  /// Walks the SQL aggregation rows, converts each `(qty, instrument)`
  /// to the profile instrument on its own day, and buckets the results
  /// by `(financialMonth, categoryId)`. Conversion runs outside the
  /// `database.read` closure (in this async helper) so the `Database`
  /// reference stays inside the snapshot.
  ///
  /// `handlers.handleUnparseableDay` lets the caller route malformed
  /// `day` strings to a logger without coupling this helper to a
  /// specific `Logger` instance. `handlers.handleConversionFailure` is
  /// invoked once per failing row so each failure surfaces individually
  /// in diagnostics rather than being collapsed into one outer failure.
  /// Recognised conversion failures mark the dependent financial month
  /// unavailable; unknown errors rethrow after the walk. A
  /// `CancellationError` propagates immediately from the batch call.
  ///
  /// All rows' `(qty, instrument, day)` conversions resolve in a single
  /// `convertResultBatch(_:)`; the outcomes stay index-aligned with the
  /// rows so the per-row failure callbacks still fire in row order.
  @concurrent
  static func assembleExpenseBreakdown(
    aggregation: ExpenseBreakdownAggregation,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    monthEnd: Int,
    handlers: ExpenseBreakdownHandlers
  ) async throws -> [ExpenseBreakdown] {
    let plan = Self.planExpenseBreakdown(
      aggregation: aggregation, profileInstrument: profileInstrument)
    for dayString in plan.unparseableDays {
      handlers.handleUnparseableDay(dayString)
    }
    // One batched conversion for every parseable row; `CancellationError`
    // propagates straight out (never reaching the per-row failure path).
    let outcomes = try await conversionService.convertResultBatch(plan.requests)

    var buckets: [String: [UUID?: InstrumentAmount]] = [:]
    var firstUnexpectedError: Error?
    // Strict Rule 11 (#1077): unavailability belongs to the logical
    // `(month, category)` total. A failed category must not blank an
    // independently computable sibling category in the same month.
    var unavailableKeys: Set<ExpenseBreakdownKey> = []
    for (planned, outcome) in zip(plan.parsedRows, outcomes) {
      let row = planned.row
      let day = planned.day
      let amount: InstrumentAmount
      switch outcome {
      case .value(let converted):
        amount = converted
      case .knownZero:
        // Issue #790: an `.unpriced` / `.spam` source folds to zero in
        // the profile instrument rather than failing the row.
        amount = .zero(instrument: profileInstrument)
      case .failure(let error):
        let context = ConversionFailureContext(
          day: row.day, categoryId: row.categoryId, instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        // Known conversion failures degrade at the dependent month:
        // transient prices can recover, while unsupported conversions
        // remain unavailable. Unknown errors still rethrow loudly.
        if ConversionFailureClassifier.canRepresentAsUnavailableData(error) {
          unavailableKeys.insert(
            ExpenseBreakdownKey(
              month: Self.financialMonth(for: day, monthEnd: monthEnd),
              categoryId: row.categoryId))
        } else if firstUnexpectedError == nil {
          firstUnexpectedError = error
        }
        continue
      }
      let month = Self.financialMonth(for: day, monthEnd: monthEnd)
      let current = buckets[month]?[row.categoryId] ?? .zero(instrument: profileInstrument)
      buckets[month, default: [:]][row.categoryId] = current + amount
    }
    if let firstUnexpectedError {
      throw firstUnexpectedError
    }
    return flattenExpenseBreakdownBuckets(
      buckets,
      unavailableKeys: unavailableKeys,
      profileInstrument: profileInstrument)
  }

  /// Parse every row's day, resolve its source instrument, and build the
  /// flat batch request list. Same-instrument rows still contribute a
  /// request so the outcome list stays index-aligned with the rows; the
  /// batch's same-instrument fast path resolves them to `.value` without
  /// a conversion-service hit, matching `convertedQuantity`'s short
  /// circuit.
  private static func planExpenseBreakdown(
    aggregation: ExpenseBreakdownAggregation,
    profileInstrument: Instrument
  ) -> ExpenseBreakdownPlan {
    var parsedRows: [ExpenseBreakdownParsedRow] = []
    var requests: [BatchConversionRequest] = []
    var unparseableDays: [String] = []
    for row in aggregation.rows {
      guard let day = Self.parseDayString(row.day) else {
        unparseableDays.append(row.day)
        continue
      }
      let instrument =
        aggregation.instrumentMap[row.instrumentId]
        ?? Instrument.fiat(code: row.instrumentId)
      parsedRows.append(ExpenseBreakdownParsedRow(row: row, day: day))
      requests.append(
        BatchConversionRequest(
          amount: InstrumentAmount(storageValue: row.qty, instrument: instrument),
          target: profileInstrument,
          date: day))
    }
    return ExpenseBreakdownPlan(
      parsedRows: parsedRows, requests: requests, unparseableDays: unparseableDays)
  }

  /// Emits one `ExpenseBreakdown` per non-empty `(month, category)` bucket
  /// and sorts months descending — the contract pinned by
  /// `AnalysisExpenseBreakdownTests.expenseBreakdownSortOrder`.
  ///
  /// Strict Rule 11 (#1077): each unavailable `(month, category)` total
  /// is flagged without blanking sibling categories. A key with no
  /// surviving converted row gets a zeroed placeholder retaining its
  /// category identity so it cannot be mistaken for "no activity".
  private struct ExpenseBreakdownKey: Hashable {
    let month: String
    let categoryId: UUID?
  }

  private static func flattenExpenseBreakdownBuckets(
    _ buckets: [String: [UUID?: InstrumentAmount]],
    unavailableKeys: Set<ExpenseBreakdownKey>,
    profileInstrument: Instrument
  ) -> [ExpenseBreakdown] {
    var results: [ExpenseBreakdown] = []
    for (month, categories) in buckets {
      for (categoryId, total) in categories {
        results.append(
          ExpenseBreakdown(
            categoryId: categoryId,
            month: month,
            totalExpenses: total,
            hasUnavailableData: unavailableKeys.contains(
              ExpenseBreakdownKey(month: month, categoryId: categoryId))))
      }
    }
    for key in unavailableKeys where buckets[key.month]?[key.categoryId] == nil {
      results.append(
        ExpenseBreakdown(
          categoryId: key.categoryId,
          month: key.month,
          totalExpenses: .zero(instrument: profileInstrument),
          hasUnavailableData: true))
    }
    return results.sorted { $0.month > $1.month }
  }
}
