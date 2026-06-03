import Foundation
import GRDB

extension ProfileSchema {
  /// v16 migration body. Adds the `insight_dismissal` table — one row per
  /// `InsightKind` the user has dismissed, carrying a cumulative `count` that
  /// drives `InsightRanker`'s fatigue penalty. Synced via CKSyncEngine
  /// (`InsightDismissalRecord`).
  ///
  /// `kind` is `UNIQUE`: there is exactly one tally per kind. The primary key
  /// `id` is a deterministic UUID derived from `kind` (see
  /// `InsightDismissalRow.id(for:)`), so the same kind resolves to the same
  /// record on every device and cross-device upserts collapse rather than
  /// duplicate.
  ///
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`. Rowid table (no
  /// `WITHOUT ROWID`): GRDB's `upsert` emits `RETURNING "rowid"` and
  /// `ValueObservation` hooks require a rowid table — same constraint as v14.
  static func addInsightDismissals(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE insight_dismissal (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            kind                   TEXT    NOT NULL UNIQUE,
            count                  INTEGER NOT NULL CHECK (count >= 0),
            encoded_system_fields  BLOB
        ) STRICT;
        """)
  }
}
