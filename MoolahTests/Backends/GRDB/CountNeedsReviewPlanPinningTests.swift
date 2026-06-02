import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning for `GRDBTransactionRepository.countNeedsReview()`.
/// Same methodology as `InsightDataSourcePlanPinningTests`: the perf-critical
/// signal is that the leg side of the correlated `NOT EXISTS` subquery is
/// index-driven (no bare `SCAN leg`).
///
/// The outer `"transaction"` table has no selective partial index for
/// `recur_period IS NULL` (the `transaction_scheduled` index covers the
/// complementary `IS NOT NULL` predicate for the rare scheduled rows). An
/// all-history `COUNT(*)` of posted rows drives from the full transaction
/// table; that scan is unavoidable and accepted here — the O(n) cost is
/// bounded to the transaction header rows alone, with no leg
/// materialisation. The correlated subquery short-circuits on the first
/// categorised leg, riding `leg_by_transaction` so each probe is O(log n).
@Suite("countNeedsReview plan-pinning")
struct CountNeedsReviewPlanPinningTests {
  private let query = """
    SELECT COUNT(*)
    FROM "transaction" t
    WHERE t.recur_period IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM transaction_leg leg
        WHERE leg.transaction_id = t.id
          AND leg.category_id IS NOT NULL
      )
    """

  @Test("correlated NOT EXISTS probe uses leg_by_transaction — no bare leg scan")
  func legSideUsesIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(database, query: query)
    // The correlated subquery drives via leg.transaction_id = t.id.
    // SQLite resolves this through leg_by_transaction(transaction_id),
    // so a bare SCAN of the leg alias must not appear.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
  }
}
