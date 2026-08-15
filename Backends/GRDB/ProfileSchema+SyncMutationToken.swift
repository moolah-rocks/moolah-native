import GRDB

extension ProfileSchema {
  static func addSyncMutationToken(_ database: Database) throws {
    let tables = [
      "tax_owner", "category", "account_group", "insight_dismissal",
      "wallet_sync_checkpoint", "account", "earmark", "earmark_budget_item",
      "transaction", "transaction_leg", "csv_import_profile", "import_rule",
      "transfer_suggestion",
    ]
    for table in tables {
      try database.execute(
        literal: """
          ALTER TABLE \(identifier: table)
          ADD COLUMN local_mutation_token TEXT NOT NULL DEFAULT ''
          """)
      try database.execute(
        literal: """
          CREATE TRIGGER \(identifier: "\(table)_refresh_sync_token")
          AFTER UPDATE OF needs_push ON \(identifier: table)
          WHEN NEW.needs_push = 1
          BEGIN
            UPDATE \(identifier: table)
            SET local_mutation_token = lower(hex(randomblob(16)))
            WHERE id = NEW.id;
          END
          """)
    }
  }
}
