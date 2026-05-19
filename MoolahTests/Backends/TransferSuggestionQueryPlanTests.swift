import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning test for `suggestions(touching:)`. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 the hot detection-time lookup
/// `WHERE transaction_id_a = ? OR transaction_id_b = ?` must resolve via
/// the two single-column indexes (`transfer_suggestion_by_tx_a` /
/// `transfer_suggestion_by_tx_b`), not a full-table scan. SQLite plans an
/// OR-of-two-indexed-columns as a two-search union, so the plan must
/// reference `transfer_suggestion_by_tx_` and must not contain
/// `SCAN transfer_suggestion`.
@Suite("TransferSuggestion query plan")
struct TransferSuggestionQueryPlanTests {
  @Test
  func suggestionsTouchingUsesIndexNotScan() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txId = UUID()
    try await database.read { database in
      // `SELECT *` here is wrapped in `EXPLAIN QUERY PLAN`; the planner
      // never expands the column list, so the star is fine.
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM transfer_suggestion
          WHERE transaction_id_a = ? OR transaction_id_b = ?
          """,
        arguments: [txId, txId]
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(
        plan.contains { $0.contains("USING INDEX transfer_suggestion_by_tx_") },
        "suggestions(touching:) must resolve via transfer_suggestion_by_tx_* indexes")
      #expect(
        !plan.contains { $0.contains("SCAN transfer_suggestion") },
        "suggestions(touching:) must not full-table scan transfer_suggestion")
    }
  }

  /// `fetchAll`/`observeAll` order by `suggested_at` with no supporting
  /// index — a full scan + temp-B-tree sort is intentional for this
  /// small, lifecycle-bounded table. Pinned so adding an index (which
  /// would change the plan) or dropping the ORDER BY breaks the build
  /// and forces a deliberate decision.
  @Test
  func fetchAllOrderByIsAnIntentionalScan() async throws {
    let database = try ProfileDatabase.openInMemory()
    try await database.read { database in
      let plan = try Row.fetchAll(
        database,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT * FROM transfer_suggestion ORDER BY suggested_at ASC
          """
      ).map { String(describing: $0["detail"] ?? "") }
      #expect(plan.contains { $0.contains("SCAN transfer_suggestion") })
    }
  }
}
