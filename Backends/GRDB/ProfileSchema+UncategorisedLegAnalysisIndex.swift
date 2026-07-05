// Backends/GRDB/ProfileSchema+UncategorisedLegAnalysisIndex.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v21 — adds `leg_analysis_by_type_uncategorised`, the partial covering
  /// index for the "Uncategorised" Reports row
  /// (`GRDBAnalysisRepository+UncategorisedBalances.swift`). The existing
  /// `leg_analysis_by_type_category` composite is `WHERE category_id IS NOT
  /// NULL`, so it cannot serve the uncategorised aggregation's
  /// `leg.category_id IS NULL` predicate — without this index that query
  /// falls back to a non-covering row-fetch over every in-range
  /// income/expense leg.
  ///
  /// Column order mirrors `leg_analysis_by_type_category` exactly —
  /// `(type, category_id, instrument_id, transaction_id, quantity)`, only
  /// the partial predicate flips to `IS NULL`. `category_id` **must**
  /// stay in the column list even though every row indexed here carries a
  /// NULL value: verified empirically (`EXPLAIN QUERY PLAN` against a
  /// throwaway schema) that SQLite does not use the partial predicate
  /// itself to resolve a `category_id IS NULL` filter — dropping the
  /// column from the index flips the plan from `USING COVERING INDEX` to
  /// a plain `USING INDEX` that still fetches the base row. Keeping the
  /// column, so `category_id IS NULL` becomes a normal indexed equality
  /// lookup, is what makes the read covering.
  ///
  /// `IF NOT EXISTS` is included defensively, matching
  /// `addTransactionByDateIdIndex` (v19) — GRDB wraps each migration in a
  /// transaction so re-application is impossible in practice, but the
  /// guard preserves idempotency if the migration body is ever exercised
  /// against an already-migrated database in a test fixture.
  static func addUncategorisedLegAnalysisIndex(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE INDEX IF NOT EXISTS leg_analysis_by_type_uncategorised
            ON transaction_leg(type, category_id, instrument_id, transaction_id, quantity)
            WHERE category_id IS NULL;
        """)
  }
}
