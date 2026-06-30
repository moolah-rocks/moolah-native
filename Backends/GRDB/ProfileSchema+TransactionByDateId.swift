import Foundation
import GRDB

extension ProfileSchema {
  /// v19 — adds a composite `(date DESC, id ASC)` index on `"transaction"` to
  /// support the `ORDER BY date DESC, id ASC LIMIT/OFFSET` page query in
  /// `GRDBTransactionRepository`. The existing single-column `transaction_by_date`
  /// index covers `date` only; without an `id` tiebreaker column in the index
  /// the planner must sort equal-date rows with a temp B-tree, making the page
  /// boundary non-deterministic under `LIMIT` when dates tie. This composite
  /// index makes the page query O(window + index walk) instead of
  /// O(table + sort) for the common case.
  ///
  /// The name `transaction_by_date_id` is distinct from the existing
  /// `transaction_by_date` single-column index; both coexist. Per
  /// `guides/DATABASE_SCHEMA_GUIDE.md` §4, the existing single-column index is
  /// NOT a prefix-duplicate of this composite: the composite has a DESC
  /// direction on `date` (the single-column index has the default ASC), so
  /// SQLite treats them as different B-trees and the planner can choose each
  /// for different query shapes.
  ///
  /// `"transaction"` is double-quoted throughout because `transaction` is a SQL
  /// reserved word. `IF NOT EXISTS` is included defensively — GRDB wraps each
  /// migration in a transaction so re-application is impossible in practice, but
  /// the guard preserves idempotency if the migration body is ever exercised
  /// against an already-migrated database in a test fixture.
  static func addTransactionByDateIdIndex(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE INDEX IF NOT EXISTS transaction_by_date_id
            ON "transaction"(date DESC, id ASC);
        """)
  }
}
