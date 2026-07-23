import Foundation
import GRDB

extension ProfileSchema {
  /// v27 — local-only semantic insight display history. The primary key is the
  /// stable `Insight.presentationKey`; changing amounts and period buckets do
  /// not create a new row for an ongoing observation, while event-specific
  /// keys (such as transaction IDs) remain separate.
  ///
  /// Retention is 90 days, enforced by
  /// `GRDBInsightDisplayHistoryRepository.recordShown`. At that age the
  /// ranker's display penalty has decayed to effectively zero. The table is
  /// `WITHOUT ROWID` because it is a short, TEXT-primary-key lookup table, and
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`.
  static func addInsightDisplayHistory(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE insight_display_history (
            presentation_key  TEXT NOT NULL PRIMARY KEY,
            last_shown_at     TEXT NOT NULL
        ) STRICT, WITHOUT ROWID;
        """)
  }
}
