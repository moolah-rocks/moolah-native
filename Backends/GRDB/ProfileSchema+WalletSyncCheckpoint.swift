// Backends/GRDB/ProfileSchema+WalletSyncCheckpoint.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v20 migration body. Adds the synced `wallet_sync_checkpoint` table —
  /// one row per auto-imported account carrying the highest confirmed block
  /// number, synced cross-device via CKSyncEngine
  /// (`WalletSyncCheckpointRecord`). This is a SEPARATE table from the
  /// per-device, local-only `wallet_sync_state` (v8): that one each device
  /// owns privately, while this one is shared so a fresh device can bootstrap
  /// from a peer's checkpoint.
  ///
  /// `id` is `BLOB` matching `account.id` (UUID-as-BLOB). `record_name` is
  /// the canonical CloudKit record name. `encoded_system_fields` caches the
  /// CKRecord change tag; `needs_push` is the local-only dirty flag (0/1),
  /// matching every other synced table since v17.
  ///
  /// `STRICT` per `guides/DATABASE_SCHEMA_GUIDE.md`. Rowid table (no
  /// `WITHOUT ROWID`): GRDB's `upsert` emits `RETURNING "rowid"` and
  /// `ValueObservation` hooks require a rowid table — same constraint as the
  /// v16 `insight_dismissal` synced table.
  ///
  /// Retention: one row per account, keyed by account id. AccountRepository.delete(_:)
  /// must also delete the corresponding wallet_sync_checkpoint row (and, once wired,
  /// queue a CloudKit delete) — otherwise deleted accounts leave orphaned synced rows.
  /// No FK constraint (per-profile schema is FK-free); cascade is a repository-layer
  /// contract, wired in the checkpoint repository work.
  static func addWalletSyncCheckpoint(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE wallet_sync_checkpoint (
            id                        BLOB    NOT NULL PRIMARY KEY,
            record_name               TEXT    NOT NULL UNIQUE,
            last_synced_block_number  INTEGER NOT NULL,
            encoded_system_fields     BLOB,
            needs_push                INTEGER NOT NULL DEFAULT 0
                CHECK (needs_push IN (0, 1))
        ) STRICT;
        """)
  }
}
