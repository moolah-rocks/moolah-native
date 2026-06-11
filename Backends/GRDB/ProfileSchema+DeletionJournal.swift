import Foundation
import GRDB

extension ProfileSchema {
  /// v18 — adds the local-only `deletion_journal` table (issue #1090). Each row
  /// is a durable deletion intent for a synced record in this profile's data
  /// zone: written inside the same transaction that deletes the local row,
  /// replayed as a `.deleteRecord` on engine start, cleared on confirmation or
  /// on re-create. Because it lives in GRDB (not the CKSyncEngine state blob) a
  /// deletion survives engine-down timing and a sync-state reset, closing the
  /// resurrection window where a pending delete held only in engine state is
  /// lost.
  ///
  /// `(zone_name, record_name)` is the primary key — 1:1 with a `CKRecord.ID`,
  /// so re-deleting is idempotent. `STRICT` per
  /// `guides/DATABASE_SCHEMA_GUIDE.md`; the statement is a string literal (no
  /// interpolation) per `guides/DATABASE_CODE_GUIDE.md` §4.
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
