import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning test for the "Uncategorised" Reports-row
/// aggregation. Split into its own `@Suite` file (rather than folded into
/// `AnalysisAggregationPlanPinningTests`) purely to keep that sibling file
/// under the `file_length` budget — see its file header for the shared
/// `EXPLAIN QUERY PLAN` methodology this test follows (same temp B-tree
/// GROUP/ORDER acceptance rationale applies here too).
@Suite("Analysis aggregation plan-pinning — Uncategorised")
struct UncategorisedBalancesPlanPinningTests {
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  @Test("fetchUncategorisedBalances SQL uses leg_analysis_by_type_uncategorised covering index")
  func fetchUncategorisedBalancesUsesUncategorisedCoveringIndex() throws {
    let database = try makeDatabase()
    // Mirrors the exact SQL shape used by
    // `GRDBAnalysisRepository.makeUncategorisedBalancesRequest` with no
    // optional filters set: GROUP BY `(DATE(t.date), instrument_id)`
    // restricted to non-scheduled legs of a given type carrying no
    // category. `category_id` is not in the SELECT/GROUP BY list, but
    // `leg_analysis_by_type_uncategorised` still carries it (type,
    // category_id, instrument_id, transaction_id, quantity) — SQLite
    // needs the column physically indexed to resolve `category_id IS
    // NULL` as a covering equality lookup; dropping it from the index
    // flips the plan to a non-covering `USING INDEX` that still fetches
    // the base row.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               leg.instrument_id   AS instrument_id,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND t.date >= ? AND t.date <= ?
          AND leg.type = ?
          AND leg.category_id IS NULL
        GROUP BY DATE(t.date), leg.instrument_id
        ORDER BY DATE(t.date) ASC
        """,
      arguments: [Date(), Date(), "expense"])
    #expect(detail.contains("leg_analysis_by_type_uncategorised"))
    #expect(detail.contains("USING COVERING INDEX"))
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg leg`. Pin against the alias rather than the bare
    // table name (which would never match this query's plan and would
    // silently pass even on a full scan).
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }
}
