import Foundation
import GRDB

extension ProfileSchema {
  /// v17 — adds the local-only `needs_push` dirty flag to every syncable
  /// per-profile table. `needs_push = 1` means the row has a local change
  /// not yet confirmed uploaded to CloudKit; the fetched-changes apply
  /// path reads it inside its write transaction and refuses to overwrite
  /// such a row's field values (issue #1081). The column never crosses
  /// the CloudKit wire and is absent from every Row struct's CodingKeys,
  /// so `upsert` leaves it untouched. Existing rows default to 0 (clean):
  /// any genuinely-unpushed row already has `encoded_system_fields IS NULL`
  /// and is re-queued by the first-start self-heal, so a 0 default cannot
  /// lose an edit at migration time.
  static func addNeedsPush(_ database: Database) throws {
    let tables = [
      "account", "account_group", "category", "earmark", "earmark_budget_item",
      "investment_value", "\"transaction\"", "transaction_leg",
      "transfer_suggestion", "insight_dismissal", "csv_import_profile", "import_rule",
    ]
    for table in tables {
      try database.execute(
        sql: "ALTER TABLE \(table) ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0;")
    }
  }
}
