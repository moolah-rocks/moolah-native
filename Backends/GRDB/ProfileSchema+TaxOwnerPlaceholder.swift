import GRDB

extension ProfileSchema {
  /// v26 — distinguish the generated default tax owner from explicit synced data.
  static func addTaxOwnerPlaceholderMarker(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE tax_owner
          ADD COLUMN is_implicit_placeholder INTEGER
              CHECK (is_implicit_placeholder IN (0, 1));
        """)
  }
}
