import Foundation
import GRDB

extension GRDBTransactionRepository {
  /// SQL `COUNT` of posted transactions with uncategorised income/expense legs.
  /// Never materialises transaction rows — uses a correlated `NOT EXISTS`
  /// subquery so the planner can terminate early per outer row once it
  /// finds a categorised leg. Drives the categorise-backlog insight nudge.
  ///
  /// The query matches rows that are BOTH posted (`recur_period IS NULL`,
  /// excludes scheduled/recurring templates) AND have uncategorised
  /// category-bearing legs (`Transaction.needsReview`).
  func countNeedsReview(excludingInstrumentIds instrumentIds: Set<String>) async throws -> Int {
    try await database.read { database in
      let nonSpamClause: SQL =
        instrumentIds.isEmpty
        ? SQL("")
        : SQL(
          """
          AND EXISTS (
            SELECT 1 FROM transaction_leg leg
            WHERE leg.transaction_id = t.id
              AND leg.instrument_id NOT IN \(instrumentIds)
          )
          """)
      let sql: SQL =
        """
        SELECT COUNT(*)
        FROM "transaction" t
        WHERE t.recur_period IS NULL
          AND EXISTS (
            SELECT 1 FROM transaction_leg leg
            WHERE leg.transaction_id = t.id
              AND leg.type IN ('income', 'expense')
          )
          AND NOT EXISTS (
            SELECT 1 FROM transaction_leg leg
            WHERE leg.transaction_id = t.id
              AND leg.type IN ('income', 'expense')
              AND leg.category_id IS NOT NULL
          )
          \(nonSpamClause)
        """
      return try SQLRequest<Int>(literal: sql).fetchOne(database) ?? 0
    }
  }
}
