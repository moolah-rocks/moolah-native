import Foundation
import GRDB

/// SQL aggregation + Swift assembly helpers for `fetchCategoryBalances`.
///
/// Mirrors the `+ExpenseBreakdown.swift` shape: every helper is
/// `static` and takes its dependencies (database, instruments,
/// conversion service) as parameters so this sibling-file extension
/// doesn't reach into the main class's `private` stored properties.
///
/// The SQL groups by `(DATE(t.date), category_id, instrument_id)` — with
/// NO `category_id IS NOT NULL` filter — and the per-row conversion runs
/// in Swift so the per-day rate-cache equivalence (Rule 5 of
/// `INSTRUMENT_CONVERSION_GUIDE.md`) holds: each summed
/// `(day, category, instrument)` tuple converts at the rate effective on
/// `day`. `assembleCategoryBalances` routes null-`category_id` rows into
/// `CategoryBalances.uncategorised` and non-null rows into
/// `CategoryBalances.byCategory` — one query and one batch conversion
/// serve both the Reports categorised breakdown and the "Uncategorised"
/// row (see
/// `plans/2026-07-05-reports-uncategorised-row-plan.md`, "Design
/// (revised — single combined query)").
extension GRDBAnalysisRepository {
  // MARK: - Row / Aggregation Types

  /// One row of the SQL aggregation that drives `fetchCategoryBalances`.
  /// `day` is the ISO-8601 `YYYY-MM-DD` string returned by `DATE(t.date)`
  /// — parsed in Swift on the way out of the read closure so the
  /// `Database` reference doesn't escape into the conversion service.
  /// `categoryId` is nullable — a `nil` row is an uncategorised leg,
  /// routed to `CategoryBalances.uncategorised` by
  /// `assembleCategoryBalances`.
  struct CategoryBalancesRow: Sendable {
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
  struct CategoryBalancesAggregation: Sendable {
    let rows: [CategoryBalancesRow]
    let instrumentMap: [String: Instrument]
  }

  /// Diagnostic context passed to the conversion-failure handler so the
  /// caller's logger can identify which `(day, category, instrument)`
  /// tuple failed without coupling this helper to a `Logger` instance.
  /// Mirrors `ConversionFailureContext` on `+ExpenseBreakdown.swift`;
  /// `categoryId` is nullable — a failing uncategorised row logs with
  /// `categoryId == nil`.
  struct CategoryBalancesFailureContext: Sendable {
    let day: String
    let categoryId: UUID?
    let instrumentId: String
  }

  /// Bundle of per-row diagnostic callbacks used by
  /// `assembleCategoryBalances`, so `assembleCategoryBalances` takes
  /// one parameter instead of several. Matches `ExpenseBreakdownHandlers`
  /// on `+ExpenseBreakdown.swift`.
  struct CategoryBalancesHandlers: Sendable {
    let handleUnparseableDay: @Sendable (String) -> Void
    let handleConversionFailure: @Sendable (Error, CategoryBalancesFailureContext) -> Void
  }

  /// Bundle of optional filter values passed from the public
  /// `fetchCategoryBalances` entry point down to the SQL composer,
  /// collapsing the static helper's parameter list while allowing each
  /// caller to surface its own `TransactionFilter` projection.
  struct CategoryBalancesFilterArgs: Sendable {
    let dateRange: ClosedRange<Date>
    let transactionType: TransactionType
    let accountId: UUID?
    let earmarkId: UUID?
    let payee: String?
    let categoryIds: Set<UUID>
  }

  // MARK: - Query Building

  /// Runs the per-(day, category, instrument) SUM(quantity) aggregation
  /// pinned by
  /// `AnalysisAggregationPlanPinningTests.fetchCategoryBalancesUsesCategoryIndex`.
  ///
  /// **Account-type neutral.** Every income/expense leg counts toward
  /// the breakdown regardless of which account holds it — a dividend
  /// or brokerage fee booked against an investment account belongs in
  /// the income/expense report just like a salary or a grocery shop on
  /// a bank account. This matches `fetchIncomeAndExpense`'s contract
  /// (see `+IncomeAndExpenseAggregation.swift`). Trade and transfer
  /// legs are excluded by `leg.type = ?` (the bound `transactionType`
  /// is always `.income` or `.expense`).
  ///
  /// **No `category_id` filter.** The query intentionally does NOT
  /// restrict `category_id` — null-category rows are the "Uncategorised"
  /// total, aggregated in this same pass (see `assembleCategoryBalances`).
  /// `category_id` is still selected and grouped on so the Swift assembly
  /// can route each row to `CategoryBalances.byCategory` or
  /// `.uncategorised`.
  ///
  /// **`categoryIds` parameterisation.** SQLite cannot bind a
  /// variable-length array to a single named parameter; an
  /// `IN (:categoryIds)` raw bind would fail at runtime for any
  /// `categoryIds.count != 1`. GRDB's `SQL` literal interpolation
  /// renders `\(set)` as a parameterised list — the project-approved
  /// escape hatch documented in `DATABASE_CODE_GUIDE.md` §4. The
  /// composer falls through to a no-op clause when the set is empty
  /// so the planner doesn't see a degenerate `IN ()`.
  static func fetchCategoryBalancesAggregation(
    database: any DatabaseReader,
    instruments: [String: Instrument],
    args: CategoryBalancesFilterArgs
  ) async throws -> CategoryBalancesAggregation {
    try await database.read { database -> CategoryBalancesAggregation in
      let request = Self.makeCategoryBalancesRequest(args: args)
      let sqlRows = try Row.fetchAll(database, request)
      var rows: [CategoryBalancesRow] = []
      rows.reserveCapacity(sqlRows.count)
      for row in sqlRows {
        guard let day: String = row["day"] else { continue }
        guard let instrumentId: String = row["instrument_id"] else { continue }
        guard let qty: Int64 = row["qty"] else { continue }
        // `category_id` is genuinely nullable here — a `nil` row is an
        // uncategorised leg, not a parse failure, so it must NOT be
        // dropped by a `guard let`.
        let categoryId: UUID? = row["category_id"]
        rows.append(
          CategoryBalancesRow(
            day: day,
            categoryId: categoryId,
            instrumentId: instrumentId,
            qty: qty))
      }
      return CategoryBalancesAggregation(rows: rows, instrumentMap: instruments)
    }
  }

  /// Builds the `SQLRequest<Row>` for the category-balances
  /// aggregation. Composed via `SQL` literal interpolation so:
  ///
  /// 1. `categoryIds` (a variable-length set) interpolates safely as a
  ///    parameterised `IN (?,?,?)` list — see GRDB's
  ///    `appendInterpolation(_ sequence:)` overload. SQLite's
  ///    `IN (:array)` named bind is a hard NO for arrays; this
  ///    interpolation is the project-approved escape hatch
  ///    (`DATABASE_CODE_GUIDE.md` §4 lists `SQL` literal interpolation
  ///    as the safe dynamic-composition path).
  /// 2. Each optional filter clause (`accountId`, `earmarkId`, `payee`,
  ///    `categoryIds`) renders as either an `AND <predicate>` fragment
  ///    or an empty `SQL("")` placeholder. The plan-pinning tests
  ///    exercise the with-filter shapes (`accountId`, `earmarkId`)
  ///    independently; the no-filter shape uses the same SQL skeleton
  ///    minus the optional fragments.
  ///
  /// The `transactionType` value comes from a Swift enum with a closed
  /// raw-value set, so its interpolation cannot inject SQL even though
  /// `String` is the underlying type.
  private static func makeCategoryBalancesRequest(
    args: CategoryBalancesFilterArgs
  ) -> SQLRequest<Row> {
    let lower = args.dateRange.lowerBound
    let upper = args.dateRange.upperBound
    let typeRaw = args.transactionType.rawValue

    let accountClause: SQL =
      args.accountId.map { SQL("AND leg.account_id = \($0)") } ?? SQL("")
    let earmarkClause: SQL =
      args.earmarkId.map { SQL("AND leg.earmark_id = \($0)") } ?? SQL("")
    let payeeClause: SQL =
      args.payee.map { SQL("AND t.payee = \($0)") } ?? SQL("")
    let categoryClause: SQL =
      args.categoryIds.isEmpty
      ? SQL("")
      : SQL("AND leg.category_id IN \(args.categoryIds)")

    // Columns are table-qualified (`leg.`, `t.`) defensively — none of
    // the current tables in scope share a column name, but if a future
    // filter fragment joins a table that exposes one of these columns,
    // a bare reference in GROUP BY would silently become ambiguous.
    // Keeping the qualifications now means a future join won't tip the
    // SELECT/GROUP BY shape over.
    let literal: SQL = """
      SELECT DATE(t.date)        AS day,
             leg.category_id     AS category_id,
             leg.instrument_id   AS instrument_id,
             SUM(leg.quantity)   AS qty
      FROM transaction_leg leg
      JOIN "transaction"    t ON leg.transaction_id = t.id
      WHERE t.recur_period IS NULL
        AND t.date >= \(lower) AND t.date <= \(upper)
        AND leg.type = \(typeRaw)
        \(accountClause)
        \(earmarkClause)
        \(payeeClause)
        \(categoryClause)
      GROUP BY DATE(t.date), leg.category_id, leg.instrument_id
      ORDER BY DATE(t.date) ASC, leg.category_id ASC
      """
    return SQLRequest<Row>(literal: literal)
  }

  // MARK: - Assembly

  /// The batch plan for the category-balances walk: the rows that parsed
  /// (retained so the index-aligned outcome can rebuild each bucket and
  /// failure context), the flat request list, and the day-strings that
  /// failed to parse so the caller surfaces them before the batch.
  private struct CategoryBalancesPlan {
    let parsedRows: [CategoryBalancesRow]
    let requests: [BatchConversionRequest]
    let unparseableDays: [String]
  }

  /// Walks the SQL aggregation rows, converts each `(qty, instrument)`
  /// to the target instrument on its own day, and accumulates totals —
  /// per `categoryId` for non-null rows, into a single running total for
  /// null-`categoryId` rows. Conversion runs outside the `database.read`
  /// closure (in this async helper) so the `Database` reference stays
  /// inside the snapshot.
  ///
  /// The `uncategorised` accumulator starts `nil` and is only seeded
  /// (`.zero(instrument: targetInstrument)` plus the row's converted
  /// amount) the first time a null-`categoryId` row contributes — so
  /// `CategoryBalances.uncategorised == nil` means "no uncategorised legs
  /// in range" and callers can omit UI for that case rather than treating
  /// a `.zero` total as "there were uncategorised legs that happened to
  /// net to zero".
  ///
  /// Mirrors `assembleExpenseBreakdown`'s per-row error contract:
  /// `handleUnparseableDay` and `handleConversionFailure` are invoked
  /// per failing row so each failure surfaces individually in
  /// diagnostics. Strict Rule 11 (#1077): a *transient* failure
  /// (`ConversionFailureClassifier.isTransient`) degrades per-row — the
  /// row's contribution is skipped (added to neither `byCategory` nor
  /// `uncategorised`) and `hasUnavailableData` is flagged on the result
  /// — while a *structural* failure preserves the loud rethrow that
  /// signals a genuinely incomplete result: the walk continues
  /// processing remaining rows then re-throws the first structural
  /// error after the walk. A `CancellationError` is rethrown immediately
  /// (it propagates straight out of the batch call) and never folded
  /// into the conversion-failure path. Categorised and uncategorised
  /// rows share this one batch conversion, so a structural failure
  /// still fails the whole call exactly as before this field existed —
  /// there is no partial-failure surface between the two buckets for
  /// structural errors; only transient errors degrade per-row.
  ///
  /// All rows' `(qty, instrument, day)` conversions resolve in a single
  /// `convertResultBatch(_:)` — the row order of the request list is
  /// preserved in the outcomes, so the per-row failure callbacks still
  /// fire in row order before the rethrow.
  @concurrent
  static func assembleCategoryBalances(
    aggregation: CategoryBalancesAggregation,
    targetInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    handlers: CategoryBalancesHandlers
  ) async throws -> CategoryBalances {
    let plan = Self.planCategoryBalances(
      aggregation: aggregation, targetInstrument: targetInstrument)
    for dayString in plan.unparseableDays {
      handlers.handleUnparseableDay(dayString)
    }
    // One batched conversion for every parseable row; `CancellationError`
    // propagates straight out (never reaching the per-row failure path).
    let outcomes = try await conversionService.convertResultBatch(plan.requests)

    var byCategory: [UUID: InstrumentAmount] = [:]
    var uncategorised: InstrumentAmount?
    var firstConversionError: Error?
    var hasUnavailableData = false
    for (row, outcome) in zip(plan.parsedRows, outcomes) {
      let amount: InstrumentAmount
      switch outcome {
      case .value(let converted):
        amount = converted
      case .knownZero:
        // Issue #790: an `.unpriced` / `.spam` source folds to zero in
        // the target rather than failing the row.
        amount = .zero(instrument: targetInstrument)
      case .failure(let error):
        let context = CategoryBalancesFailureContext(
          day: row.day,
          categoryId: row.categoryId,
          instrumentId: row.instrumentId)
        handlers.handleConversionFailure(error, context)
        // Transient price-availability failures (a throttled provider, a
        // day not yet warmed — issue #1075) degrade per-row: skip this
        // row's contribution and render the rest. Only a *structural*
        // failure preserves the loud rethrow that signals a genuinely
        // incomplete result. Strict Rule 11 (#1077): a transient skip
        // flags the whole result unavailable.
        if ConversionFailureClassifier.isTransient(error) {
          hasUnavailableData = true
        } else if firstConversionError == nil {
          firstConversionError = error
        }
        continue
      }
      if let categoryId = row.categoryId {
        let current = byCategory[categoryId] ?? .zero(instrument: targetInstrument)
        byCategory[categoryId] = current + amount
      } else {
        let current = uncategorised ?? .zero(instrument: targetInstrument)
        uncategorised = current + amount
      }
    }
    if let firstConversionError {
      // Preserve the existing observable behaviour (throws on a
      // structural conversion error) while having logged every per-row
      // failure.
      throw firstConversionError
    }
    return CategoryBalances(
      byCategory: byCategory, uncategorised: uncategorised, hasUnavailableData: hasUnavailableData)
  }

  /// Parse every row's day, resolve its source instrument, and build the
  /// flat batch request list. Same-instrument rows still contribute a
  /// request so the outcome list stays index-aligned with the rows; the
  /// batch's same-instrument fast path resolves them to `.value` without
  /// a conversion-service hit, matching `convertedQuantity`'s short
  /// circuit.
  private static func planCategoryBalances(
    aggregation: CategoryBalancesAggregation,
    targetInstrument: Instrument
  ) -> CategoryBalancesPlan {
    var parsedRows: [CategoryBalancesRow] = []
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
      parsedRows.append(row)
      requests.append(
        BatchConversionRequest(
          amount: InstrumentAmount(storageValue: row.qty, instrument: instrument),
          target: targetInstrument,
          date: day))
    }
    return CategoryBalancesPlan(
      parsedRows: parsedRows, requests: requests, unparseableDays: unparseableDays)
  }
}
