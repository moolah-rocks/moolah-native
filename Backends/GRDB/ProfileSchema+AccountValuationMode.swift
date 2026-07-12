// Backends/GRDB/ProfileSchema+AccountValuationMode.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v6 migration body. Adds `valuation_mode` to the `account` table.
  /// Default `'recordedValue'` backfills every existing row so the
  /// CHECK constraint stays satisfied; per
  /// `guides/DATABASE_SCHEMA_GUIDE.md` enum-shaped TEXT columns must
  /// pin the legacy wire values used by older app versions.
  static func addAccountValuationMode(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE account
          ADD COLUMN valuation_mode TEXT NOT NULL DEFAULT 'recordedValue'
            CHECK (valuation_mode IN ('recordedValue', 'calculatedFromTrades'));
        """)
  }
}
