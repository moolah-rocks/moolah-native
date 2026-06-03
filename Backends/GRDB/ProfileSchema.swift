// Backends/GRDB/ProfileSchema.swift

import Foundation
import GRDB

/// Schema definition for a profile's `data.sqlite`.
///
/// Each profile has exactly one such database. Migration history:
/// `v1_initial` — rate caches (FX, stocks, crypto). See
/// `ProfileSchema+RateCaches.swift`.
/// `v2_csv_import_and_rules` — CSV import profiles and import rules.
/// See `ProfileSchema+CSVImportAndRules.swift`.
/// `v3_core_financial_graph` — core financial graph (instrument,
/// account, transaction, transaction_leg, category, earmark,
/// earmark_budget_item, investment_value). See
/// `ProfileSchema+CoreFinancialGraph.swift`.
/// `v4_rate_cache_without_rowid` — rebuilds the three rate-cache
/// `*_meta` tables as `WITHOUT ROWID` so they round-trip through
/// `record.insert(database)` (with `persistenceConflictPolicy =
/// .replace`) instead of `record.upsert(database)` — GRDB 7's
/// `upsert` hard-codes `RETURNING "rowid"` which fails against
/// rowid-less tables. See `ProfileSchema+RateCacheWithoutRowid.swift`.
/// `v5_drop_foreign_keys` — recreates the four child tables of the
/// core financial graph (`category`, `earmark_budget_item`,
/// `transaction_leg`, `investment_value`) without any FK clauses.
/// See `ProfileSchema+DropForeignKeys.swift` for rationale.
/// `v6_account_valuation_mode` — adds the `valuation_mode` column to
/// the `account` table (per-account choice between recorded value and
/// calculated-from-trades). See
/// `ProfileSchema+AccountValuationMode.swift`.
/// `v7_purge_intraday_cached_prices` — one-shot `DELETE FROM` of all
/// six rate-cache tables to clear poisoned intraday rows persisted by
/// pre-cap builds. See `ProfileSchema+PurgeIntradayCaches.swift` and
/// `Shared/PriceCacheCap.swift` for the cap-at-yesterday rule that
/// prevents re-poisoning.
/// `v8_add_crypto_wallet_fields` — adds `wallet_address`/`chain_id`
/// to `account` (rebuilding the table to widen the type CHECK to
/// include `'crypto'`), `external_id` + partial-unique dedup index
/// to `transaction_leg`, `pricing_status` to `instrument`, and the
/// per-device `wallet_sync_state` table. See
/// `ProfileSchema+CryptoWalletFields.swift`.
/// `v9_add_counterparty_address` — adds `counterparty_address` to
/// `transaction_leg`. Populated by `TransferEventBuilder` from the
/// Alchemy transfer's `from`/`to` (whichever isn't this wallet);
/// `nil` for non-crypto legs and gas/self-send legs. Surfaced in the
/// transaction detail's "On-chain counterparty" row. See
/// `ProfileSchema+CounterpartyAddress.swift`.
/// `v10_drop_shared_instrument_legacy` — drops the seven legacy
/// per-profile tables (`instrument`, `exchange_rate`,
/// `exchange_rate_meta`, `stock_price`, `stock_ticker_meta`,
/// `crypto_price`, `crypto_token_meta`). Their data lives in the
/// shared profile-index registry, so the per-profile copies have no
/// reader. Permitted per `guides/DATABASE_SCHEMA_GUIDE.md` §1 rule 3 /
/// §6 rule 7. See `ProfileSchema+DropSharedInstrumentLegacy.swift` for
/// the full rationale.
/// `v11_add_exchange_account_fields` — rebuilds account to widen the
/// type CHECK to include `'exchange'` and adds the CHECK-pinned
/// `exchange_provider` column. See
/// `ProfileSchema+ExchangeAccountFields.swift`.
/// `v12_add_transfer_detection` — fuzzy transfer detection. Adds
/// `transfer_suggestion_*` and `import_origin_kind` +
/// `import_origin_incoming_*` to `transaction` (all additive nullable;
/// NULL kind = legacy single-origin), and the synced
/// `dismissed_transfer_pair` table (content-addressed `id`, two
/// tx-id columns + indexes). See
/// `ProfileSchema+TransferDetection.swift`.
/// `v13_transfer_suggestion_record` — replaces the denormalised
/// transfer-suggestion columns and the `dismissed_transfer_pair` table
/// with the synced `transfer_suggestion` record table. See
/// `ProfileSchema+TransferSuggestion.swift`.
/// `v14_account_groups` — adds the `account_group` table and an
/// additive `group_id` column on `account` (no FK; sync delivery can
/// deliver an Account ahead of its AccountGroup, so the lookup layer
/// resolves unknown ids to nil instead of relying on the database).
/// See `ProfileSchema+AccountGroups.swift`.
/// `v15_account_group_ui_state` — adds the local-only `account_group_ui`
/// table for sidebar expand / collapse state. NOT synced via CloudKit
/// (per-device UX preference, not data). FK with `ON DELETE CASCADE`
/// against `account_group(id)` reaps rows automatically when their
/// parent group is deleted. See
/// `ProfileSchema+AccountGroupUIState.swift`.
/// `v16_insight_dismissals` — adds the synced `insight_dismissal` table:
/// one row per `InsightKind` the user has dismissed, carrying a cumulative
/// `count` that drives `InsightRanker`'s fatigue penalty. `kind` is
/// `UNIQUE`; the primary key is a deterministic UUID derived from `kind`
/// so the same kind resolves to the same record on every device. See
/// `ProfileSchema+InsightDismissals.swift`.
///
/// **Retention policy for the cache tables.** The six rate-cache
/// tables are kept forever — needed for historic-conversion
/// correctness on reports older than the upstream rate APIs can serve
/// (see `guides/DATABASE_SCHEMA_GUIDE.md` §9). The retained copy lives
/// on the **shared** `profile-index.sqlite` DB, not per-profile; the
/// per-profile copies are dropped as duplicated derived caches.
///
/// Each migration body lives in its own sibling-extension file so
/// `ProfileSchema.swift` stays a small index of registered migrations.
/// New migrations get a new sibling file, registered here. Migration
/// IDs are frozen forever once shipped; splitting later is fine,
/// merging post-ship is not.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema
/// follows.
enum ProfileSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on
  /// the stable string IDs of registered migrations).
  static let version = 16

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1_initial", migrate: createInitialTables)
    migrator.registerMigration(
      "v2_csv_import_and_rules", migrate: createCSVImportAndRulesTables)
    migrator.registerMigration(
      "v3_core_financial_graph", migrate: createCoreFinancialGraphTables)
    migrator.registerMigration(
      "v4_rate_cache_without_rowid", migrate: rebuildRateCacheMetaWithoutRowid)
    migrator.registerMigration(
      "v5_drop_foreign_keys", migrate: dropForeignKeys)
    migrator.registerMigration(
      "v6_account_valuation_mode", migrate: addAccountValuationMode)
    migrator.registerMigration(
      "v7_purge_intraday_cached_prices", migrate: purgeIntradayCachedPrices)
    migrator.registerMigration(
      "v8_add_crypto_wallet_fields", migrate: addCryptoWalletFields)
    migrator.registerMigration(
      "v9_add_counterparty_address", migrate: addCounterpartyAddressToTransactionLeg)
    migrator.registerMigration(
      "v10_drop_shared_instrument_legacy", migrate: dropSharedInstrumentLegacy)
    migrator.registerMigration(
      "v11_add_exchange_account_fields", migrate: addExchangeAccountFields)
    migrator.registerMigration(
      "v12_add_transfer_detection", migrate: addTransferDetection)
    migrator.registerMigration(
      "v13_transfer_suggestion_record", migrate: addTransferSuggestion)
    migrator.registerMigration(
      "v14_account_groups", migrate: addAccountGroups)
    migrator.registerMigration(
      "v15_account_group_ui_state", migrate: addAccountGroupUIState)
    migrator.registerMigration(
      "v16_insight_dismissals", migrate: addInsightDismissals)

    return migrator
  }
}
