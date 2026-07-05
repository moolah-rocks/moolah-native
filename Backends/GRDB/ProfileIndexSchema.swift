// Backends/GRDB/ProfileIndexSchema.swift

import Foundation
import GRDB

/// Schema definition for the app-scoped `profile-index.sqlite`.
///
/// One database per app install. Holds one row per CloudKit profile so
/// the profile picker can list profiles before any of them is
/// activated. Independent of any per-profile `data.sqlite` — no FKs in
/// or out.
///
/// A separate file (rather than a table inside `data.sqlite`) is
/// justified because the index has a materially different lifetime than
/// per-profile data: it must be readable before any profile is
/// activated, it survives every profile delete, and its access pattern
/// (one read at launch, occasional writes when profiles change) does
/// not benefit from sharing the per-profile WAL.
///
/// Migration history:
/// `v1_initial`                    — the `profile` table.
/// `v2_data_format_version`        — adds `data_format_version INTEGER NOT NULL DEFAULT 0`.
/// `v3_shared_instrument_registry` — adds the shared `instrument` table
///   plus the six rate-cache tables, so spam decisions, discovered-token
///   resolutions, and price-cache rows propagate across every profile on
///   the same iCloud account. See
///   `ProfileIndexSchema+SharedInstrumentRegistry.swift`.
/// `v4_needs_push`                 — adds the local-only `needs_push`
///   dirty flag to the `profile` table (mirrors the per-profile v17
///   migration; issue #1081). See `ProfileIndexSchema+NeedsPush.swift`.
/// `v5_deletion_journal`           — adds the `deletion_journal` table for
///   durable CloudKit deletion intents (issue #1090). See
///   `ProfileIndexSchema+DeletionJournal.swift`.
/// `v6_purge_rate_caches`          — DELETE FROM all six rate-cache tables
///   so gappy legacy rows are flushed before the contiguous-fill era. See
///   `ProfileIndexSchema+PurgeRateCaches.swift`.
/// `v7_purge_crypto_price_cache`   — DELETE FROM `crypto_price` +
///   `crypto_token_meta` so the daily-gap rows cached before the DefiLlama
///   12h-oversampling fix re-backfill densely. Both tables together: the
///   cache bounds that drive `ContiguousFetchPlanner` live in
///   `crypto_token_meta`, so dropping only the prices would leave the planner
///   believing the gappy interior is covered. See
///   `ProfileIndexSchema+PurgeCryptoPriceCache.swift`.
/// `v8_crypto_first_traded_on`     — adds `crypto_token_meta.first_traded_on`
///   (nullable ISO YYYY-MM-DD) for confirmed cross-provider first-trade dates.
///   NULL means "not yet confirmed". Pre-first-trade prices are valued at $0
///   (.knownZero). See `ProfileIndexSchema+CryptoFirstTradedOn.swift`.
/// `v9_add_instrument_alias_of`     — adds the local-only `instrument.alias_of`
///   (nullable TEXT) + `instrument_by_alias` partial index. Points a retired
///   cross-chain crypto id at its canonical id; never synced (out of
///   `InstrumentRow.CodingKeys`/`toCKRecord`). See
///   `ProfileIndexSchema+InstrumentAliasOf.swift`.
///
/// Each migration body is registered here. Once shipped, migration IDs
/// are frozen forever; splitting later is fine, merging post-ship is
/// not. Migration bodies live in sibling
/// `ProfileIndexSchema+<Name>.swift` extension files so this file stays
/// a small index of registered migrations.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema
/// follows.
enum ProfileIndexSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on
  /// the stable string IDs of registered migrations).
  static let version = 10

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1_initial", migrate: createProfileTable)
    migrator.registerMigration(
      "v2_data_format_version", migrate: addDataFormatVersionColumn)
    migrator.registerMigration(
      "v3_shared_instrument_registry",
      migrate: createSharedInstrumentRegistryTables)
    migrator.registerMigration("v4_needs_push", migrate: addNeedsPush)
    migrator.registerMigration("v5_deletion_journal", migrate: addDeletionJournal)
    migrator.registerMigration("v6_purge_rate_caches", migrate: purgeRateCaches)
    migrator.registerMigration(
      "v7_purge_crypto_price_cache", migrate: purgeCryptoPriceCache)
    migrator.registerMigration(
      "v8_crypto_first_traded_on", migrate: addCryptoFirstTradedOn)
    migrator.registerMigration(
      "v9_add_instrument_alias_of", migrate: addInstrumentAliasOf)
    migrator.registerMigration(
      "v10_drop_cryptocompare_symbol", migrate: dropCryptocomplareSymbolColumn)

    return migrator
  }

  private static func createProfileTable(_ database: Database) throws {
    try database.execute(
      sql: """
        -- WITHOUT ROWID: not used; encoded_system_fields BLOB dominates
        -- row size, which makes WITHOUT ROWID's interior-page packing a
        -- net loss (per `guides/DATABASE_SCHEMA_GUIDE.md` §3 decision
        -- table).
        CREATE TABLE profile (
            id                          BLOB    NOT NULL PRIMARY KEY,
            record_name                 TEXT    NOT NULL UNIQUE,
            label                       TEXT    NOT NULL,
            currency_code               TEXT    NOT NULL,
            financial_year_start_month  INTEGER NOT NULL
                CHECK (financial_year_start_month BETWEEN 1 AND 12),
            created_at                  TEXT    NOT NULL,
            encoded_system_fields       BLOB
        ) STRICT;

        -- Drives `loadCloudProfiles`'s SortDescriptor(\\.createdAt).
        CREATE INDEX profile_by_created_at ON profile(created_at);
        """)
  }

  private static func addDataFormatVersionColumn(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE profile
          ADD COLUMN data_format_version INTEGER NOT NULL DEFAULT 0;
        """)
  }
}
