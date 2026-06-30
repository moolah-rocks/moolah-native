import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning for `GRDBTransactionRepository`'s after-page
/// subtotal scan (`subtotalsAfterPage`), which runs on every page fetch for an
/// account-scoped view and feeds the running-balance column. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 this perf-critical shape must be pinned
/// so an index regression breaks the build rather than landing as a silent
/// table scan.
///
/// The query filters a transaction-leg set by both the member account set and
/// the after-page transaction ids: `account_id IN (…) AND transaction_id IN
/// (…)`. The group case widens the account side from a single equality to a
/// multi-value `IN`, so it is pinned separately from the single-account shape.
@Suite("Transaction fetch plan-pinning")
struct TransactionFetchPlanPinningTests {
  @Test("subtotalsAfterPage compound IN filter uses a leg index, not a table scan")
  func subtotalsAfterPageCompoundFilterUsesIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id FROM transaction_leg
        WHERE account_id IN (?, ?)
          AND transaction_id IN (?, ?)
        """,
      arguments: [UUID(), UUID(), UUID(), UUID()])
    // Either leg index (by account or by transaction) keeps this off a full
    // scan; the regression signal is a SCAN of transaction_leg.
    #expect(detail.contains("leg_by_"))
    #expect(!detail.contains("SCAN transaction_leg"))
  }
}
