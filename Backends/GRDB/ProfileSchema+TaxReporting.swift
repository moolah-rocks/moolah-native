// Backends/GRDB/ProfileSchema+TaxReporting.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v23 — tax reporting ownership and category treatment.
  ///
  /// `tax_owner` is synced profile data. Account/category owner assignments are
  /// separate join tables so SQL reports can resolve ownership without parsing
  /// blobs. Empty join rows mean "inherit the profile default owner".
  static func addTaxReporting(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE tax_owner (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            kind                   TEXT    NOT NULL CHECK (kind IN ('individual', 'trust')),
            encoded_system_fields  BLOB,
            needs_push             INTEGER NOT NULL DEFAULT 0
                CHECK (needs_push IN (0, 1))
        ) STRICT;

        CREATE TABLE account_tax_owner (
            account_id  BLOB    NOT NULL,
            owner_id    BLOB    NOT NULL,
            position    INTEGER NOT NULL CHECK (position >= 0),
            PRIMARY KEY (account_id, owner_id)
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX account_tax_owner_by_account_position
            ON account_tax_owner(account_id, position);
        CREATE INDEX account_tax_owner_by_owner
            ON account_tax_owner(owner_id);

        CREATE TABLE category_tax_owner (
            category_id BLOB    NOT NULL,
            owner_id    BLOB    NOT NULL,
            position    INTEGER NOT NULL CHECK (position >= 0),
            PRIMARY KEY (category_id, owner_id)
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX category_tax_owner_by_category_position
            ON category_tax_owner(category_id, position);
        CREATE INDEX category_tax_owner_by_owner
            ON category_tax_owner(owner_id);

        ALTER TABLE category
          ADD COLUMN is_tax_reportable INTEGER NOT NULL DEFAULT 0
              CHECK (is_tax_reportable IN (0, 1));

        ALTER TABLE account
          ADD COLUMN tax_owner_ids_encoded TEXT;

        ALTER TABLE category
          ADD COLUMN tax_owner_ids_encoded TEXT;
        """)
  }
}
