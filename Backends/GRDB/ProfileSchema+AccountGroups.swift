import Foundation
import GRDB

extension ProfileSchema {
  /// v14 migration body. Adds the `account_group` table (synced via
  /// CKSyncEngine — wired in a follow-up migration step) and an
  /// additive `group_id` column on `account` for the back-reference.
  ///
  /// `account.group_id` is intentionally NOT a foreign key. Sync
  /// delivery can place an `Account` ahead of its `AccountGroup`; an
  /// FK constraint would reject the insert. The lookup layer treats
  /// unknown ids as nil and the account renders as standalone until
  /// the group arrives.
  ///
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`. Rowid table (no
  /// `WITHOUT ROWID`) — same constraint as v12/v13/v4: GRDB's `upsert`
  /// emits `RETURNING "rowid"` for the repository's optimistic write
  /// path, and `ValueObservation` hooks require a rowid table.
  static func addAccountGroups(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_group (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            bucket                 TEXT    NOT NULL CHECK (bucket IN ('current', 'investments')),
            instrument_id          TEXT    NOT NULL,
            position               INTEGER NOT NULL CHECK (position >= 0),
            encoded_system_fields  BLOB
        ) STRICT;

        CREATE INDEX account_group_by_bucket_position
            ON account_group (bucket, position);

        ALTER TABLE account ADD COLUMN group_id BLOB;
        CREATE INDEX account_by_group_id ON account (group_id);
        """)
  }
}
