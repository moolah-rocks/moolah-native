import Foundation
import GRDB

extension GRDBTransactionRepository {
  /// SQL `COUNT` of posted transactions whose every leg is uncategorised.
  /// Never materialises transaction rows — uses a correlated `NOT EXISTS`
  /// subquery so the planner can terminate early per outer row once it
  /// finds a categorised leg. Drives the categorise-backlog insight nudge.
  ///
  /// The query matches rows that are BOTH posted (`recur_period IS NULL`,
  /// excludes scheduled/recurring templates) AND have every leg uncategorised
  /// (`legs.allSatisfy { $0.categoryId == nil }`). Note that
  /// `Transaction.needsReview` itself does not include the posted constraint
  /// — it applies to any transaction type.
  func countNeedsReview() async throws -> Int {
    try await database.read { database in
      let sql: SQL =
        """
        SELECT COUNT(*)
        FROM "transaction" t
        WHERE t.recur_period IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM transaction_leg leg
            WHERE leg.transaction_id = t.id
              AND leg.category_id IS NOT NULL
          )
        """
      return try SQLRequest<Int>(literal: sql).fetchOne(database) ?? 0
    }
  }
}
