import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning for the SQL shapes `GRDBTransactionRepository`
/// runs on every transaction-list page load: the paged page query, the
/// `COUNT(*)` total, the after-page id window, and the after-page
/// per-instrument subtotal aggregate that feeds the running-balance column.
/// Per `guides/DATABASE_CODE_GUIDE.md` §6 these perf-critical shapes are
/// pinned so an index regression breaks the build rather than landing as a
/// silent table scan.
///
/// The SQL strings here mirror the requests built in
/// `GRDBTransactionRepository+Fetch.swift` (`filteredTransactionRequest`,
/// `orderedFilteredRequest`, the `fetchCount`, and `subtotalsAfterPage`).
/// Each shape is pinned in both the no-leg-filter case (only
/// `recur_period IS NULL`) and the account-filter case (`id IN (SELECT
/// transaction_id FROM transaction_leg WHERE account_id IN (?, ?))`), since
/// the planner picks a different driving table once a leg subquery is
/// present.
@Suite("Transaction fetch plan-pinning")
struct TransactionFetchPlanPinningTests {

  // MARK: - Helpers

  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  // MARK: - After-page subtotal aggregate

  @Test("subtotalsAfterPage SQL aggregate rides the leg account index, not a leg scan")
  func subtotalsAfterPageCompoundFilterUsesIndex() throws {
    let database = try makeDatabase()
    // Mirrors the rewritten `subtotalsAfterPage`: a single
    // `SUM(quantity) GROUP BY instrument_id` over member-account legs
    // whose transaction is in the after-page window, expressed as
    // `transaction_id IN (<ordered filtered request LIMIT -1 OFFSET ?>)`.
    // The group case (`account_id IN (?, ?)`) subsumes the single-account
    // shape. The driving leg read must ride `leg_by_account`; the
    // regression signal is a bare `SCAN transaction_leg`. The inner
    // after-page subquery rides `transaction_by_date_id`, so the outer
    // `"transaction"` table is never fully scanned either.
    let detail = try planDetail(
      database,
      query: """
        SELECT instrument_id, SUM(quantity)
        FROM transaction_leg
        WHERE account_id IN (?, ?)
          AND transaction_id IN (
            SELECT id FROM "transaction"
            WHERE recur_period IS NULL
            ORDER BY date DESC, id ASC
            LIMIT -1 OFFSET ?)
        GROUP BY instrument_id
        """,
      arguments: [UUID(), UUID(), 50])
    #expect(detail.contains("leg_by_account"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
  }

  // MARK: - Page query (LIMIT/OFFSET)

  @Test("page query without a leg filter rides transaction_by_date_id")
  func pageQueryNoLegFilterUsesDateIdIndex() throws {
    let database = try makeDatabase()
    // Mirrors `orderedFilteredRequest(filter:).limit(pageSize, offset:)`
    // for a global/non-scheduled view. The `date DESC, id ASC` ordering
    // is satisfied directly by `transaction_by_date_id`, so there is no
    // temp B-tree sort and no full scan.
    let detail = try planDetail(
      database,
      query: """
        SELECT * FROM "transaction"
        WHERE recur_period IS NULL
        ORDER BY date DESC, id ASC
        LIMIT ? OFFSET ?
        """,
      arguments: [50, 0])
    #expect(detail.contains("transaction_by_date_id"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
  }

  @Test("page query with an account filter avoids a transaction scan via the leg index")
  func pageQueryWithAccountFilterAvoidsFullScan() throws {
    let database = try makeDatabase()
    // Mirrors a single-account / group page: the leg subquery is the
    // selective driver, so the planner reaches `"transaction"` by primary
    // key (`SEARCH … USING INDEX sqlite_autoindex_transaction_1`) rather
    // than scanning it, and the ordering falls to a temp B-tree. The
    // `transaction_by_date_id` index is therefore NOT used in this shape
    // — that is the planner's choice once a selective leg filter is
    // present, so we pin only the no-full-scan invariant plus the
    // `leg_by_account` participation.
    let detail = try planDetail(
      database,
      query: """
        SELECT * FROM "transaction"
        WHERE recur_period IS NULL
          AND id IN (
            SELECT transaction_id FROM transaction_leg
            WHERE account_id IN (?, ?))
        ORDER BY date DESC, id ASC
        LIMIT ? OFFSET ?
        """,
      arguments: [UUID(), UUID(), 50, 0])
    #expect(detail.contains("leg_by_account"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
  }

  // MARK: - Count query

  @Test("count query without a leg filter is a plain table scan, never a sort")
  func countQueryNoLegFilterScansWithoutSort() throws {
    let database = try makeDatabase()
    // `SELECT COUNT(*) … WHERE recur_period IS NULL` must visit every
    // non-scheduled row, and no index covers the `recur_period IS NULL`
    // side (the partial `transaction_scheduled` index holds only the
    // NON-NULL rows). A full `SCAN "transaction"` is therefore the
    // inherent, optimal plan here — there is nothing to index away. We
    // pin that it stays a plain scan and never regresses into a temp
    // B-tree sort or a needless leg-index detour. (A NULL-side
    // `recur_period` index is out of scope for this work and is not
    // warranted just to count.)
    let detail = try planDetail(
      database,
      query: """
        SELECT COUNT(*) FROM "transaction"
        WHERE recur_period IS NULL
        """)
    #expect(!detail.contains("USE TEMP B-TREE"))
    #expect(!detail.contains("transaction_leg"))
  }

  @Test("count query with an account filter avoids a transaction scan via the leg index")
  func countQueryWithAccountFilterAvoidsFullScan() throws {
    let database = try makeDatabase()
    // With a selective leg subquery the count drives off `leg_by_account`
    // and reaches `"transaction"` by primary key, so neither table is
    // fully scanned.
    let detail = try planDetail(
      database,
      query: """
        SELECT COUNT(*) FROM "transaction"
        WHERE recur_period IS NULL
          AND id IN (
            SELECT transaction_id FROM transaction_leg
            WHERE account_id IN (?, ?))
        """,
      arguments: [UUID(), UUID()])
    #expect(detail.contains("leg_by_account"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
  }

  // MARK: - After-page id window (LIMIT -1 OFFSET)

  @Test("after-page id window without a leg filter rides transaction_by_date_id")
  func afterPageIdWindowNoLegFilterUsesDateIdIndex() throws {
    let database = try makeDatabase()
    // The inner subquery of `subtotalsAfterPage`, in its no-account-scope
    // shape: the ordered filtered request windowed past the page. Rides
    // `transaction_by_date_id`, no full scan.
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction"
        WHERE recur_period IS NULL
        ORDER BY date DESC, id ASC
        LIMIT -1 OFFSET ?
        """,
      arguments: [50])
    #expect(detail.contains("transaction_by_date_id"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
  }

  @Test("after-page id window with an account filter avoids a transaction scan via the leg index")
  func afterPageIdWindowWithAccountFilterAvoidsFullScan() throws {
    let database = try makeDatabase()
    // Same as the account-filtered page query: the leg subquery drives,
    // `"transaction"` is reached by primary key, ordering falls to a temp
    // B-tree, and `transaction_by_date_id` is not used. Pin only the
    // no-full-scan invariant plus `leg_by_account` participation.
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM "transaction"
        WHERE recur_period IS NULL
          AND id IN (
            SELECT transaction_id FROM transaction_leg
            WHERE account_id IN (?, ?))
        ORDER BY date DESC, id ASC
        LIMIT -1 OFFSET ?
        """,
      arguments: [UUID(), UUID(), 50])
    #expect(detail.contains("leg_by_account"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
  }
}
