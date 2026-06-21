import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the analysis aggregations and
/// the still-intentional full-table reads on the analysis hot path.
///
/// Same `EXPLAIN QUERY PLAN` methodology as `AnalysisPlanPinningTests`
/// (see its file header).
///
/// **Temp B-tree GROUP/ORDER lines are accepted across this whole
/// file.** Aggregations group and order by `day = DATE(t.date)` — a
/// derived expression with no index keying, so SQLite has no choice
/// but to materialise the groups and the sort in temp B-trees.
/// Trying to forbid `USE TEMP B-TREE FOR GROUP BY` /
/// `USE TEMP B-TREE FOR ORDER BY` would force the planner away from
/// the covering index entirely. The perf-critical signals are the
/// bare-SCAN rejection (`planHasFullTableScanOf`) and the
/// `USING COVERING INDEX` assertion where applicable.
@Suite("Analysis aggregation plan-pinning")
struct AnalysisAggregationPlanPinningTests {
  /// `makeDatabase` and `planDetail` are shared with
  /// `AnalysisPlanPinningTests` and `CSVImportPlanPinningTests` via
  /// `PlanPinningTestHelpers`.
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  // MARK: - Aggregations

  @Test("computePositions JOIN+GROUP BY avoids a transaction_leg SCAN")
  func computePositionsAvoidsScan() throws {
    let database = try makeDatabase()
    // Mirrors `GRDBAccountRepository.computePositions(database:instruments:)`.
    // The JOIN+GROUP BY needs an index on the leg table that lets SQLite
    // group `(account_id, instrument_id)` without scanning every leg.
    let detail = try planDetail(
      database,
      query: """
        SELECT leg.account_id     AS account_id,
               leg.instrument_id  AS instrument_id,
               SUM(leg.quantity)  AS quantity
        FROM transaction_leg AS leg
        JOIN "transaction" AS txn ON leg.transaction_id = txn.id
        WHERE txn.recur_period IS NULL
          AND leg.account_id IS NOT NULL
        GROUP BY leg.account_id, leg.instrument_id
        HAVING SUM(leg.quantity) <> 0
        """)
    // Either of the leg-side indexes is acceptable: the partial
    // `leg_by_account` and the covering `leg_analysis_by_type_account`
    // both let SQLite find rows with non-NULL account_id without a
    // full table scan.
    let usesAcceptableIndex =
      detail.contains("leg_by_account")
      || detail.contains("leg_analysis_by_type_account")
    #expect(usesAcceptableIndex)
    // SQLite emits `SCAN <alias>` when the FROM clause aliases the
    // table — `transaction_leg AS leg` here. Asserting on the bare
    // table name would be a false-negative pin; pin against the alias
    // the planner actually emits.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("fetchExpenseBreakdown SQL uses leg_analysis_by_type_category covering index")
  func fetchExpenseBreakdownUsesCategoryCoveringIndex() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL shape used by
    // `GRDBAnalysisRepository.fetchExpenseBreakdown(monthEnd:after:)`:
    // GROUP BY `(DATE(t.date), category_id, instrument_id)` restricted
    // to non-scheduled expense legs with a category. `account_id` is
    // intentionally absent from the WHERE clause for two reasons,
    // documented on `fetchExpenseBreakdownAggregation`:
    // 1. CloudKit parity — categorised expense legs without an account
    //    must appear in the breakdown.
    // 2. Covering — `account_id` is not in
    //    `leg_analysis_by_type_category`'s column list, so adding the
    //    predicate forces a base-row fetch and flips the plan from
    //    `USING COVERING INDEX` to plain `USING INDEX`.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               leg.category_id     AS category_id,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type = 'expense'
          AND leg.category_id IS NOT NULL
          AND (? IS NULL OR t.date >= ?)
        GROUP BY day, category_id, instrument_id
        ORDER BY day ASC, category_id ASC
        """,
      arguments: [Date?.none, Date?.none])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(detail.contains("USING COVERING INDEX"))
    // SQLite emits `SCAN <alias>` when the FROM clause aliases the
    // table (here `transaction_leg leg`); pin against the alias rather
    // than the bare table name to avoid a false-negative assertion.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    // Temp B-tree GROUP/ORDER lines accepted — see file-header rationale.
    // The covering-index property captured by `USING COVERING INDEX`
    // above is the perf-critical signal: it flips when the leg-side
    // composite loses a column or the WHERE clause grows a predicate
    // the partial index doesn't cover.
  }

  @Test("computeEarmarkPositions JOIN+GROUP BY avoids a transaction_leg SCAN")
  func computeEarmarkPositionsAvoidsScan() throws {
    let database = try makeDatabase()
    // Mirrors `GRDBEarmarkRepository.computeEarmarkPositions`.
    let detail = try planDetail(
      database,
      query: """
        SELECT leg.earmark_id     AS earmark_id,
               leg.instrument_id  AS instrument_id,
               leg.type           AS type,
               leg.quantity       AS quantity
        FROM transaction_leg AS leg
        JOIN "transaction" AS txn ON leg.transaction_id = txn.id
        WHERE txn.recur_period IS NULL
          AND leg.earmark_id IS NOT NULL
        """)
    // Either the partial `leg_by_earmark` or the covering
    // `leg_analysis_by_earmark_type` is acceptable; both keep the
    // earmark-non-NULL filter off a full scan.
    let usesAcceptableIndex =
      detail.contains("leg_by_earmark")
      || detail.contains("leg_analysis_by_earmark_type")
    #expect(usesAcceptableIndex)
    // Pin the covering composite specifically: the SELECT touches only
    // `(earmark_id, type, instrument_id, transaction_id, quantity)`,
    // which is exactly `leg_analysis_by_earmark_type`'s column list, so
    // the planner is expected to pick it and emit `USING COVERING INDEX`.
    // Mirrors the `fetchDailyBalancesEarmarkDimensionUsesEarmarkIndex`
    // pin in `DailyBalancesPlanPinningTests`.
    #expect(detail.contains("leg_analysis_by_earmark_type"))
    #expect(detail.contains("USING COVERING INDEX"))
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg AS leg`. Pin against the alias.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  // MARK: - fetchCategoryBalances

  @Test("fetchCategoryBalances SQL uses leg_analysis_by_type_category covering index")
  func fetchCategoryBalancesUsesCategoryIndex() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL shape used by
    // `GRDBAnalysisRepository.fetchCategoryBalances(...)` with no
    // optional filters set: GROUP BY `(DATE(t.date), category_id,
    // instrument_id)` restricted to non-scheduled categorised legs of
    // a given type in a date range. The aggregation does not join
    // to `account` — investment-account legs are intentionally
    // included alongside the rest (matches
    // `fetchIncomeAndExpense`'s contract). Without the LEFT JOIN
    // the plan resolves to `USING COVERING INDEX` on
    // `leg_analysis_by_type_category` because every leg column
    // touched (`type`, `category_id`, `instrument_id`,
    // `transaction_id`, `quantity`) sits in the composite.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               leg.category_id     AS category_id,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND t.date >= ? AND t.date <= ?
          AND leg.type = ?
          AND leg.category_id IS NOT NULL
        GROUP BY DATE(t.date), leg.category_id, leg.instrument_id
        ORDER BY DATE(t.date) ASC, leg.category_id ASC
        """,
      arguments: [Date(), Date(), "expense"])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(detail.contains("USING COVERING INDEX"))
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg leg`. Pin against the alias rather than the
    // bare table name (which would never match this query's plan and
    // would silently pass even on a full scan).
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("fetchCategoryBalances with accountId filter consults leg_by_account")
  func fetchCategoryBalancesAccountFilterConsultsAccountIndex() throws {
    let database = try makeDatabase()
    // With the optional `accountId` filter set, the WHERE clause grows
    // an `AND leg.account_id = ?` predicate. Any of the leg-side
    // indexes that lets SQLite avoid a full scan is acceptable —
    // `leg_by_account` or `leg_analysis_by_type_account` (both
    // account-aware) or `leg_analysis_by_type_category` (which covers
    // the SELECT and post-filters `account_id` against the base row).
    // We don't pin which one the planner picks; the SCAN-rejection
    // assertions below are what catch a regression.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               leg.category_id     AS category_id,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND t.date >= ? AND t.date <= ?
          AND leg.type = ?
          AND leg.category_id IS NOT NULL
          AND leg.account_id = ?
        GROUP BY DATE(t.date), leg.category_id, leg.instrument_id
        ORDER BY DATE(t.date) ASC, leg.category_id ASC
        """,
      arguments: [Date(), Date(), "expense", UUID()])
    let usesAcceptableLegIndex =
      detail.contains("leg_by_account")
      || detail.contains("leg_analysis_by_type_account")
      || detail.contains("leg_analysis_by_type_category")
    #expect(usesAcceptableLegIndex)
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg leg`. Pin against the alias.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  // MARK: - fetchIncomeAndExpense

  @Test("fetchIncomeAndExpense SQL uses leg_analysis_by_type_account index without scanning")
  func fetchIncomeAndExpenseUsesTypeAccountIndex() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL shape used by
    // `GRDBAnalysisRepository.fetchIncomeAndExpense(monthEnd:after:)`:
    // GROUP BY `(DATE(t.date), instrument_id)` with six conditional
    // sums, restricted to non-scheduled legs and a LEFT JOIN to
    // `account` for the investment-account routing.
    //
    // Like `fetchCategoryBalances`, we do NOT assert
    // `USING COVERING INDEX`. Every CASE branch reads `a.type` from the
    // `LEFT JOIN account`, so the plan is driven by a leg-side index plus
    // a PK lookup into `account`; the perf-critical signal is "no full
    // table scan on leg, transaction, or account", and the bare
    // `SCAN leg` (without `USING ...`) is what `planHasFullTableScanOf`
    // catches.
    //
    // `incomeAndExpenseMirrorSQL` references the production constant
    // directly so the mirror can never drift from the real query.
    let detail = try planDetail(
      database, query: incomeAndExpenseMirrorSQL, arguments: [Date?.none, Date?.none])
    // At least one of the leg-side analysis indexes must drive the read
    // — the WHERE has no leg-side equality predicate, so the planner
    // typically chooses the type-account composite or a partial index
    // that's order-compatible with the GROUP BY.
    let usesAcceptableLegIndex =
      detail.contains("leg_analysis_by_type_account")
      || detail.contains("leg_analysis_by_type_category")
      || detail.contains("leg_analysis_by_earmark_type")
      || detail.contains("leg_by_account")
      || detail.contains("leg_by_earmark")
    #expect(usesAcceptableLegIndex)
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg leg`. Pin against the alias rather than the
    // bare table name (which would silently pass even on a full
    // scan because the planner's output never uses the bare name when
    // the query aliases the table).
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
    // The LEFT JOIN to `account` should resolve via the PK
    // (`sqlite_autoindex_account_1`) or `account_by_type` rather than a
    // full scan — pin that no `SCAN account` line slips into the plan.
    #expect(!detail.contains("SCAN account"))
  }

  // MARK: - fetchCategoryBalances earmark filter

  @Test("fetchCategoryBalances with earmarkId filter consults leg_by_earmark")
  func fetchCategoryBalancesEarmarkFilterConsultsEarmarkIndex() throws {
    let database = try makeDatabase()
    // With the optional `earmarkId` filter set, the WHERE clause grows
    // an `AND leg.earmark_id = ?` predicate. Either of the earmark-side
    // partial indexes — `leg_by_earmark` or
    // `leg_analysis_by_earmark_type` — is acceptable, and the
    // category-side `leg_analysis_by_type_category` is permitted to
    // win the leg-side scan. The pin asserts at least one earmark- or
    // category-aware index participates in the plan.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               leg.category_id     AS category_id,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND t.date >= ? AND t.date <= ?
          AND leg.type = ?
          AND leg.category_id IS NOT NULL
          AND leg.earmark_id = ?
        GROUP BY DATE(t.date), leg.category_id, leg.instrument_id
        ORDER BY DATE(t.date) ASC, leg.category_id ASC
        """,
      arguments: [Date(), Date(), "expense", UUID()])
    let usesAcceptableLegIndex =
      detail.contains("leg_by_earmark")
      || detail.contains("leg_analysis_by_earmark_type")
      || detail.contains("leg_analysis_by_type_category")
    #expect(usesAcceptableLegIndex)
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg leg`. Pin against the alias.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }
}

/// Mirror of the `fetchIncomeAndExpense` aggregation SQL, kept at file
/// scope so the plan-pinning test body stays within the function-length
/// limit. The investment-like list comes straight from the production
/// constant (`AccountType.isInvestmentLike`), so the mirror can never
/// drift from the real query when an investment-like account type is
/// added.
private let incomeAndExpenseMirrorSQL = """
  SELECT
      DATE(t.date)         AS day,
      leg.instrument_id    AS instrument_id,
      SUM(
          (CASE WHEN leg.type IN ('income', 'trade')
                 AND a.type IS NOT NULL
                 AND a.type NOT IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
                THEN leg.quantity ELSE 0 END)
        - (CASE WHEN leg.type IN ('income', 'trade')
                 AND leg.earmark_id IS NOT NULL
                THEN leg.quantity ELSE 0 END)
      )                                              AS income_qty,
      SUM(
          (CASE WHEN leg.type IN ('expense', 'transfer')
                 AND a.type IS NOT NULL
                 AND a.type NOT IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
                THEN leg.quantity ELSE 0 END)
        - (CASE WHEN leg.type IN ('expense', 'transfer')
                 AND leg.earmark_id IS NOT NULL
                THEN leg.quantity ELSE 0 END)
      )                                              AS expense_qty,
      SUM(CASE WHEN leg.type IN ('income', 'trade')
                AND a.type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
               THEN leg.quantity ELSE 0 END)        AS investment_income_qty,
      SUM(CASE WHEN leg.type IN ('expense', 'transfer')
                AND a.type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
               THEN leg.quantity ELSE 0 END)        AS investment_expense_qty
  FROM transaction_leg leg
  JOIN "transaction"    t ON leg.transaction_id = t.id
  LEFT JOIN account     a ON leg.account_id = a.id
  WHERE t.recur_period IS NULL
    AND (? IS NULL OR t.date >= ?)
  GROUP BY day, leg.instrument_id
  ORDER BY day ASC
  """
