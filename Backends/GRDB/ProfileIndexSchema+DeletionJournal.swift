import Foundation
import GRDB

extension ProfileIndexSchema {
  /// v5 — adds the `deletion_journal` table to the profile-index DB (issue
  /// #1090). Records durable deletion intents for profile-index-zone records
  /// (`ProfileRow`s and shared `InstrumentRecord`s). Living in the index DB
  /// (not a per-profile DB) means a deleted profile's index-record deletion
  /// outlives its per-profile data DB teardown, so the profile's CloudKit
  /// record is reliably deleted rather than resurrecting as an empty shell.
  ///
  /// Same shape as the per-profile `deletion_journal` (`ProfileSchema+DeletionJournal`):
  /// `(zone_name, record_name)` primary key, `STRICT`, string-literal SQL.
  static func addDeletionJournal(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE deletion_journal (
            zone_name    TEXT   NOT NULL,
            record_name  TEXT   NOT NULL,
            record_type  TEXT   NOT NULL,
            queued_at    REAL   NOT NULL,
            PRIMARY KEY (zone_name, record_name)
        ) STRICT;
        """)
  }
}
