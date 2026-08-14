import GRDB

extension ProfileSchema {
  static func addAccountAutomaticSync(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE account
          ADD COLUMN is_automatic_sync_enabled INTEGER NOT NULL DEFAULT 1
            CHECK (is_automatic_sync_enabled IN (0, 1));
        """)
  }
}
