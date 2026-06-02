import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning for the `GRDBInsightDataSource`
/// aggregations. Same methodology as `AnalysisAggregationPlanPinningTests`
/// (see its header): the perf-critical signal is the bare-SCAN rejection
/// (`planHasFullTableScanOf`) plus the leg-side index assertion. Temp
/// B-tree GROUP / ORDER lines are accepted because every aggregation groups
/// by the derived `day = DATE(t.date)` expression.
@Suite("InsightDataSource plan-pinning")
struct InsightDataSourcePlanPinningTests {
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  @Test("dailyTotals groups by (day, instrument) off a leg index, no scan")
  func dailyTotalsAvoidsScan() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)      AS day,
               leg.instrument_id AS instrument_id,
               SUM(CASE WHEN leg.type = 'income'  THEN leg.quantity ELSE 0 END) AS income_qty,
               SUM(CASE WHEN leg.type = 'expense' THEN leg.quantity ELSE 0 END) AS expense_qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type IN ('income', 'expense')
        GROUP BY day, leg.instrument_id
        ORDER BY day ASC
        """)
    // dailyTotals is an all-history aggregation with no selective leg-side
    // equality, so the planner may legitimately drive from either side; the
    // perf-critical signal (per `PlanPinningTestHelpers`) is that the leg
    // table is never bare-scanned.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }

  @Test("categorySpend uses the leg_analysis_by_type_category index, no scan")
  func categorySpendUsesCategoryIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)      AS day,
               leg.category_id   AS dim,
               leg.instrument_id AS instrument_id,
               SUM(leg.quantity) AS qty,
               COUNT(*)          AS n
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type = 'expense'
          AND leg.category_id IS NOT NULL
          AND (? IS NULL OR t.date >= ?)
        GROUP BY day, dim, instrument_id
        ORDER BY day ASC
        """,
      arguments: [Date?.none, Date?.none])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }

  @Test("accountSpend uses the leg_analysis_by_type_account index, no scan")
  func accountSpendUsesAccountIndex() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)      AS day,
               leg.account_id    AS dim,
               leg.instrument_id AS instrument_id,
               SUM(leg.quantity) AS qty,
               COUNT(*)          AS n
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type = 'expense'
          AND leg.account_id IS NOT NULL
          AND (? IS NULL OR t.date >= ?)
        GROUP BY day, dim, instrument_id
        ORDER BY day ASC
        """,
      arguments: [Date?.none, Date?.none])
    let usesLegIndex =
      detail.contains("leg_analysis_by_type_account")
      || detail.contains("leg_by_account")
    #expect(usesLegIndex)
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }

  @Test("categorySamples window-function projection avoids a leg table scan")
  func categorySamplesAvoidsScan() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT category_id, day, instrument_id, quantity
        FROM (
          SELECT leg.category_id    AS category_id,
                 DATE(t.date)       AS day,
                 leg.instrument_id  AS instrument_id,
                 leg.quantity       AS quantity,
                 ROW_NUMBER() OVER (
                   PARTITION BY leg.category_id
                   ORDER BY t.date DESC, leg.transaction_id DESC
                 ) AS rn
          FROM transaction_leg leg
          JOIN "transaction"    t ON leg.transaction_id = t.id
          WHERE t.recur_period IS NULL
            AND leg.type = 'expense'
            AND leg.category_id IS NOT NULL
            AND (? IS NULL OR t.date >= ?)
        )
        WHERE rn <= ?
        ORDER BY category_id ASC, rn ASC
        """,
      arguments: [Date?.none, Date?.none, 200])
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }

  @Test("incomeSamples window-function projection avoids a leg table scan")
  func incomeSamplesAvoidsScan() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT day, instrument_id, quantity
        FROM (
          SELECT DATE(t.date)       AS day,
                 leg.instrument_id  AS instrument_id,
                 leg.quantity       AS quantity,
                 ROW_NUMBER() OVER (
                   ORDER BY t.date DESC, leg.transaction_id DESC
                 ) AS rn
          FROM transaction_leg leg
          JOIN "transaction"    t ON leg.transaction_id = t.id
          WHERE t.recur_period IS NULL
            AND leg.type = 'income'
            AND (? IS NULL OR t.date >= ?)
        )
        WHERE rn <= ?
        ORDER BY rn ASC
        """,
      arguments: [Date?.none, Date?.none, 200])
    let usesLegIndex =
      detail.contains("leg_analysis_by_type_account")
      || detail.contains("leg_analysis_by_type_category")
    #expect(usesLegIndex)
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }

  @Test("recentCandidates projection avoids a leg table scan")
  func recentCandidatesAvoidsScan() throws {
    let database = try makeDatabase()
    let detail = try planDetail(
      database,
      query: """
        SELECT t.id              AS txn_id,
               t.date            AS txn_date,
               DATE(t.date)      AS day,
               t.payee           AS payee,
               leg.quantity      AS quantity,
               leg.category_id   AS category_id,
               leg.account_id    AS account_id,
               leg.instrument_id AS instrument_id,
               leg.type          AS type
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND leg.type IN ('income', 'expense')
          AND (? IS NULL OR t.date >= ?)
        ORDER BY t.date DESC
        """,
      arguments: [Date?.none, Date?.none])
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }
}
