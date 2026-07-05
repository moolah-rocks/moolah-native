// Backends/GRDB/ProfileSchema+LegAnalysisCategoryIncludeNull.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v21 — widens `leg_analysis_by_type_category` from a *partial* index
  /// (`WHERE category_id IS NOT NULL`) to a full index over every row, so
  /// it can also serve the combined `fetchCategoryBalances` query that no
  /// longer filters `category_id` at the SQL layer — null-category rows
  /// now aggregate into the "Uncategorised" Reports total in the SAME
  /// pass as the categorised totals, rather than via a separate query. See
  /// `plans/2026-07-05-reports-uncategorised-row-plan.md`, "Design
  /// (revised — single combined query)".
  ///
  /// Same name, same column order —
  /// `(type, category_id, instrument_id, transaction_id, quantity)` — as
  /// the index created by `createCoreFinancialGraphTables` (v3) and
  /// recreated by `dropForeignKeys` (v5); only the partial `WHERE` clause
  /// is dropped. Those two migration bodies are frozen forever once
  /// shipped and are NOT touched here — this migration mutates the live
  /// index in place, the same pattern `v19_transaction_by_date_id` used to
  /// add a new index without touching the base schema.
  ///
  /// SQLite has no `CREATE OR REPLACE INDEX` / `ALTER INDEX`, so
  /// recreating an index under the same name requires dropping the old
  /// definition first. `IF EXISTS` / `IF NOT EXISTS` are included
  /// defensively, matching `addTransactionByDateIdIndex` (v19) — GRDB
  /// wraps each migration in a transaction so re-application is
  /// impossible in practice, but the guards preserve idempotency if the
  /// migration body is ever exercised against an already-migrated
  /// database in a test fixture.
  static func widenLegAnalysisByTypeCategoryIndex(_ database: Database) throws {
    try database.execute(
      sql: """
        DROP INDEX IF EXISTS leg_analysis_by_type_category;

        CREATE INDEX IF NOT EXISTS leg_analysis_by_type_category
            ON transaction_leg(type, category_id, instrument_id, transaction_id, quantity);
        """)
  }
}
