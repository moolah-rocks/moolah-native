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
  /// `needs_push` is a boolean (0/1), so each column carries a
  /// `CHECK (needs_push IN (0, 1))` — matching the v6 `valuation_mode`
  /// precedent. Every statement is a string literal (no `\(table)`
  /// interpolation) per `guides/DATABASE_CODE_GUIDE.md` §4.
  static func addNeedsPush(_ database: Database) throws {
    try database.execute(
      sql: "ALTER TABLE account ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE account_group ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE category ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE earmark ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE earmark_budget_item ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE investment_value ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    // `transaction` is a SQL keyword and must stay double-quoted.
    try database.execute(
      sql: "ALTER TABLE \"transaction\" ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE transaction_leg ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE transfer_suggestion ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE insight_dismissal ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE csv_import_profile ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
    try database.execute(
      sql: "ALTER TABLE import_rule ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
  }
}
