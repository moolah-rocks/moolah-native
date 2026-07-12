import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the hot read paths the GRDB
/// repositories drive against the core financial graph tables. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6, every perf-critical query must
/// have a paired plan-pinning test so that an index regression breaks
/// the build immediately rather than landing as a silent O(N) scan.
///
/// Each test opens a fresh in-memory `ProfileDatabase` (which runs the
/// migrator and creates the v3 tables and indexes), runs an `EXPLAIN
/// QUERY PLAN` over the SQL shape used by the repository, and asserts
/// that:
///
/// 1. The plan mentions the expected `USING INDEX <name>` line.
/// 2. The plan does **not** include a `SCAN` of the table — a SCAN is the
///    canonical regression signature when an index becomes unusable
///    (column rename, predicate drift, partial-index WHERE clause that
///    fails to match the predicate).
@Suite("Core financial graph plan-pinning")
struct AnalysisPlanPinningTests {

  // MARK: - Helpers

  /// `makeDatabase` and `planDetail` are shared with
  /// `AnalysisAggregationPlanPinningTests` and `CSVImportPlanPinningTests`
  /// via `PlanPinningTestHelpers`.
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  // MARK: - transaction

  @Test("fetchPayeeSuggestions matches the production query shape")
  func payeePrefixMatchesProduction() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL emitted by
    // `GRDBTransactionRepository.fetchPayeeSuggestions(prefix:)`:
    // a `lower(payee) LIKE lower(?) || '%'` autocomplete with a
    // `GROUP BY payee` aggregate and a `LIMIT 20`. The `IS NOT NULL`
    // predicate lets SQLite use the partial `transaction_by_payee`
    // index even though the `lower(...)` wrapping defeats range bounds
    // on `payee` itself — autocomplete is `LIMIT 20` so the cost stays
    // bounded. The pin asserts the partial index participates in
    // some way (covering or otherwise), and a `transaction_by_payee`
    // line in the plan is the regression signal.
    let detail = try planDetail(
      database,
      query: """
        SELECT payee
        FROM "transaction"
        WHERE payee IS NOT NULL
          AND lower(payee) LIKE lower(?) || '%'
        GROUP BY payee
        ORDER BY COUNT(*) DESC, payee ASC
        LIMIT 20
        """,
      arguments: ["X"])
    #expect(detail.contains("transaction_by_payee"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "\"transaction\""))
  }

  @Test("fetchPayeeSuggestions with excludingTransactionId still uses the payee index")
  func payeePrefixWithExclusionMatchesProduction() throws {
    let database = try makeDatabase()
    // Mirrors the `excludingTransactionId` branch of
    // `GRDBTransactionRepository.fetchPayeeSuggestions(prefix:excludingTransactionId:)`.
    // The added `id != ?` predicate must not push the planner off the
    // partial `transaction_by_payee` index — a regression here would
    // turn every keystroke into a full table scan.
    let detail = try planDetail(
      database,
      query: """
        SELECT payee
        FROM "transaction"
        WHERE payee IS NOT NULL
          AND id != ?
          AND lower(payee) LIKE lower(?) || '%'
        GROUP BY payee
        ORDER BY COUNT(*) DESC, payee ASC
        LIMIT 20
        """,
      arguments: [UUID(), "X"])
    #expect(detail.contains("transaction_by_payee"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "\"transaction\""))
  }

  @Test("transaction equality filter on payee uses the partial payee index")
  func payeeEqualityUsesPayeeIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction" WHERE payee = ?
        """,
      arguments: ["Coffee"])
    #expect(detail.contains("transaction_by_payee"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("transaction date-range filter uses transaction_by_date")
  func dateRangeUsesDateIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction" WHERE date >= ? ORDER BY date
        """,
      arguments: [Date()])
    #expect(detail.contains("transaction_by_date"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  @Test("scheduled-transaction filter uses transaction_scheduled partial index")
  func scheduledFilterUsesScheduledIndex() throws {
    let database = try makeDatabase()
    // Without ORDER BY the planner picks the partial-on-recur_period
    // index over the full transaction_by_date index. Add ORDER BY date and
    // SQLite re-routes to transaction_by_date because that one is already
    // ordered by date — outside the partial-index test's scope.
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction" WHERE recur_period IS NOT NULL
        """)
    #expect(detail.contains("transaction_scheduled"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }

  // MARK: - transaction_leg

  @Test("leg fetch by transaction_id uses leg_by_transaction")
  func legByTransactionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE transaction_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_transaction"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  @Test("leg fetch by account_id uses leg_by_account partial index")
  func legByAccountUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE account_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_account"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  @Test("leg fetch by category_id uses leg_by_category partial index")
  func legByCategoryUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE category_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_category"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  @Test("leg fetch by earmark_id uses leg_by_earmark partial index")
  func legByEarmarkUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg WHERE earmark_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("leg_by_earmark"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }

  // MARK: - earmark_budget_item

  @Test("budget-item lookup by earmark_id uses ebi_by_earmark")
  func budgetItemByEarmarkUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM earmark_budget_item WHERE earmark_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("ebi_by_earmark"))
    #expect(!detail.contains("SCAN earmark_budget_item"))
  }

  @Test("budget-item lookup by category_id uses ebi_by_category")
  func budgetItemByCategoryUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM earmark_budget_item WHERE category_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("ebi_by_category"))
    #expect(!detail.contains("SCAN earmark_budget_item"))
  }

  // MARK: - category

  @Test("category listing by parent_id uses category_by_parent")
  func categoryByParentUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM category WHERE parent_id = ?
        """,
      arguments: [UUID()])
    #expect(detail.contains("category_by_parent"))
    #expect(!detail.contains("SCAN category"))
  }

  // MARK: - account

  @Test("account ordering by position uses account_by_position")
  func accountOrderByPositionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM account ORDER BY position
        """)
    #expect(detail.contains("account_by_position"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  // MARK: - earmark

  @Test("earmark ordering by position uses earmark_by_position")
  func earmarkOrderByPositionUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM earmark ORDER BY position
        """)
    #expect(detail.contains("earmark_by_position"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

}
