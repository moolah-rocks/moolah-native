import Foundation
import GRDB

extension ProfileSchema {
  /// v13 migration body. Replaces the fuzzy-transfer-detection storage
  /// model: a detected suggestion is now a first-class synced record
  /// rather than a denormalised pair of `transaction` columns plus a
  /// negative-assertion `dismissed_transfer_pair` table.
  ///
  /// - Drops `dismissed_transfer_pair` (negative assertions carry no
  ///   meaning in the record model; no data is preserved).
  /// - Drops `transaction.transfer_suggestion_counterpart_id` and
  ///   `transaction.transfer_suggestion_suggested_at` (the denormalised
  ///   annotation; superseded by the new table).
  /// - Creates `transfer_suggestion` — synced (CKSyncEngine). `id` is a
  ///   content-addressed UUID of the unordered transaction-id pair, so
  ///   the repository's `upsert` on the PK is idempotent across devices.
  ///
  /// `WITHOUT ROWID` intentionally NOT used (same constraint as v12 /
  /// v4: `upsert` emits `RETURNING "rowid"`; ValueObservation hooks
  /// require a rowid table). Small rows; rowid overhead negligible.
  static func addTransferSuggestion(_ database: Database) throws {
    try database.execute(
      sql: """
        DROP TABLE IF EXISTS dismissed_transfer_pair;

        ALTER TABLE "transaction" DROP COLUMN transfer_suggestion_counterpart_id;
        ALTER TABLE "transaction" DROP COLUMN transfer_suggestion_suggested_at;

        CREATE TABLE transfer_suggestion (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            transaction_id_a       BLOB    NOT NULL,
            transaction_id_b       BLOB    NOT NULL,
            suggested_at           TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        CREATE INDEX transfer_suggestion_by_tx_a ON transfer_suggestion(transaction_id_a);
        CREATE INDEX transfer_suggestion_by_tx_b ON transfer_suggestion(transaction_id_b);
        """)
  }
}
