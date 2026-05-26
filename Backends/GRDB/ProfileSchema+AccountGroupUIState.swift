import Foundation
import GRDB

extension ProfileSchema {
  /// v15 migration. Adds the per-profile local-only `account_group_ui`
  /// table that backs sidebar expand / collapse state. Intentionally
  /// **not** synced via CloudKit — expand state is per-device UX
  /// preference, not data (see the Account Groups design,
  /// "Local-only state").
  ///
  /// `ON DELETE CASCADE` on `group_id` reaps the row automatically when
  /// the underlying group is deleted (locally or via incoming
  /// CKSyncEngine delete). The FK is safe here because both tables live
  /// in the same DB and the table is never written from the sync apply
  /// path — a UI-state row is only created in response to user
  /// interaction with a group that is already on-screen, so the parent
  /// row is guaranteed to exist at write time. This is the one FK in the
  /// account-groups schema; `account.group_id` (v14) deliberately has no
  /// FK because sync delivery order can place an Account ahead of its
  /// AccountGroup.
  ///
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`. Rowid table — no
  /// `WITHOUT ROWID` because the rest of the per-profile DB uses rowid
  /// tables and the row count for this table is bounded by the number of
  /// groups (always small), so there is no storage win to chase.
  static func addAccountGroupUIState(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE account_group_ui (
            group_id     BLOB    NOT NULL PRIMARY KEY
                         REFERENCES account_group(id) ON DELETE CASCADE,
            is_expanded  INTEGER NOT NULL DEFAULT 0
        ) STRICT;
        """)
  }
}
