// MoolahTests/Backends/GRDB/ProfileSchemaV10DropLegacyTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v10 drops legacy per-profile instrument tables")
struct ProfileSchemaV10DropLegacyTests {
  /// The seven legacy per-profile tables that v10 drops. Instruments
  /// now live on the shared profile-index registry; the price caches
  /// are network-derived and also persisted on the shared DB.
  private static let droppedTables = [
    "instrument",
    "exchange_rate",
    "exchange_rate_meta",
    "stock_price",
    "stock_ticker_meta",
    "crypto_price",
    "crypto_token_meta",
  ]

  /// The core financial-graph tables that must survive v10 untouched.
  private static let coreGraphTables = [
    "category",
    "account",
    "earmark",
    "earmark_budget_item",
    "transaction",
    "transaction_leg",
    "investment_value",
  ]

  /// After the full `ProfileSchema.migrator` runs (including v10), none
  /// of the seven legacy tables exist and every core-graph table does.
  @Test
  func fullMigrationDropsLegacyTablesAndKeepsCoreGraph() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      try Self.expectLegacyTablesDropped(in: database)
      for table in Self.coreGraphTables {
        let count = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
          arguments: [table])
        #expect(count == 1, "Expected core-graph table \(table) to survive; missing")
      }
    }
  }

  /// The full post-v10 set of `type='table'` names a fresh
  /// `ProfileSchema.migrator` run produces, enumerated from the
  /// surviving create migrations: v2's two CSV-import tables, v3's
  /// seven core-graph tables (its `instrument` table is dropped at
  /// v10), v8's per-device `wallet_sync_state`, and GRDB's own
  /// `grdb_migrations` bookkeeping table. The seven v10-dropped legacy
  /// tables are deliberately absent.
  private static let expectedTables: Set<String> = [
    "csv_import_profile",
    "import_rule",
    "category",
    "account",
    "earmark",
    "earmark_budget_item",
    "transaction",
    "transaction_leg",
    "investment_value",
    "wallet_sync_state",
    // v13 transfer suggestion (content-addressed pair; replaces dismissed_transfer_pair)
    "transfer_suggestion",
    // v14 account groups (synced; back-reference column added on `account`)
    "account_group",
    // v15 sidebar expand / collapse state (local-only; cascades from
    // `account_group` on delete)
    "account_group_ui",
    // v16 insight dismissals (synced per-kind fatigue tally; UNIQUE
    // constraints yield only auto-indexes, so no named index is added)
    "insight_dismissal",
    // v18 durable deletion journal (local-only; issue #1090)
    "deletion_journal",
    "grdb_migrations",
  ]

  /// The full post-v10 set of named (`type='index'`,
  /// non-`sqlite_autoindex_*`) index names, enumerated from the
  /// surviving create / rebuild migrations. The v5 / v8 table rebuilds
  /// recreate the v3 indexes verbatim, so the net set is stable; the
  /// dropped `instrument` table had no explicit named index.
  private static let expectedIndexes: Set<String> = [
    // v2 csv_import_profile / import_rule
    "csv_import_profile_account",
    "csv_import_profile_created",
    "import_rule_position",
    "import_rule_account_scope",
    // v3 category (rebuilt v5)
    "category_by_parent",
    // v3 account (rebuilt v8)
    "account_by_position",
    "account_by_type",
    // v3 earmark
    "earmark_by_position",
    // v3 earmark_budget_item (rebuilt v5)
    "ebi_by_earmark",
    "ebi_by_category",
    // v3 "transaction"
    "transaction_by_date",
    "transaction_scheduled",
    "transaction_by_payee",
    // v3 transaction_leg (rebuilt v5) + v8 dedup index
    "leg_by_transaction",
    "leg_by_account",
    "leg_by_category",
    "leg_by_earmark",
    "leg_analysis_by_type_account",
    "leg_analysis_by_type_category",
    "leg_analysis_by_earmark_type",
    "leg_dedup_by_account_external",
    // v3 investment_value (rebuilt v5)
    "iv_by_account_date_value",
    // v13 transfer suggestion
    "transfer_suggestion_by_tx_a",
    "transfer_suggestion_by_tx_b",
    // v14 account groups
    "account_group_by_bucket_position",
    "account_by_group_id",
    // v18 durable deletion journal (issue #1090)
    "deletion_journal_by_queued_at",
  ]

  /// `DATABASE_SCHEMA_GUIDE.md` §6 rule 1 golden gate: after the FULL
  /// `ProfileSchema.migrator` runs, the exact set of `type='table'`
  /// names and the exact set of named `type='index'` names must equal
  /// the hardcoded expected sets. A future migration that adds, drops,
  /// or renames any table or index then fails CI here with the drift
  /// named — forcing the change to be intentional and reviewed.
  @Test
  func fullMigrationSchemaIsGolden() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    let (tables, indexes): (Set<String>, Set<String>) = try queue.read { database in
      (
        Set(
          try String.fetchAll(
            database, sql: "SELECT name FROM sqlite_master WHERE type='table'")),
        Set(
          try String.fetchAll(
            database,
            sql: """
              SELECT name FROM sqlite_master
              WHERE type='index' AND name NOT LIKE 'sqlite_%'
              """))
      )
    }
    #expect(
      tables == Self.expectedTables,
      """
      tables drift — unexpected \(tables.subtracting(Self.expectedTables)), \
      missing \(Self.expectedTables.subtracting(tables))
      """)
    #expect(
      indexes == Self.expectedIndexes,
      """
      indexes drift — unexpected \(indexes.subtracting(Self.expectedIndexes)), \
      missing \(Self.expectedIndexes.subtracting(indexes))
      """)
  }

  /// Seeds core-graph + legacy rows at v9, runs only v10, asserts the
  /// seven legacy tables are gone and every seeded core-graph row
  /// survived. Pins the data-preservation guarantee of the destructive
  /// migration against regression.
  @Test
  func v10PreservesCoreGraphAndDropsLegacy() throws {
    let queue = try migratedQueueThroughV9()
    try seedV9Rows(into: queue)

    var v10Migrator = DatabaseMigrator()
    v10Migrator.registerMigration(
      "v10_drop_shared_instrument_legacy",
      migrate: ProfileSchema.dropSharedInstrumentLegacy)
    try v10Migrator.migrate(queue)

    try queue.read { database in
      try Self.expectLegacyTablesDropped(in: database)
      try Self.expectSeededCoreGraphPreserved(in: database)
    }
  }

  // MARK: - Helpers

  /// Asserts each of the seven legacy tables is absent from
  /// `sqlite_master`.
  private static func expectLegacyTablesDropped(in database: Database) throws {
    for table in droppedTables {
      let count = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
        arguments: [table])
      #expect(count == 0, "Expected legacy table \(table) to be dropped; still present")
    }
  }

  /// Asserts the one-row-per-table core-graph seed survived v10.
  private static func expectSeededCoreGraphPreserved(in database: Database) throws {
    #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM category") == 2)
    #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account") == 1)
    #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM earmark") == 1)
    #expect(
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM earmark_budget_item") == 1)
    #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \"transaction\"") == 1)
    #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transaction_leg") == 1)
    #expect(
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM investment_value") == 1)
  }

  /// Builds a partial migrator registering v1…v9 only — mirrors the
  /// `ProfileSchemaV5DropForeignKeysTests` pattern, extended to the
  /// real v6…v9 migration ids/functions so v10 can be exercised in
  /// isolation.
  private func migratedQueueThroughV9() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    var partial = DatabaseMigrator()
    partial.registerMigration("v1_initial", migrate: ProfileSchema.createInitialTables)
    partial.registerMigration(
      "v2_csv_import_and_rules", migrate: ProfileSchema.createCSVImportAndRulesTables)
    partial.registerMigration(
      "v3_core_financial_graph", migrate: ProfileSchema.createCoreFinancialGraphTables)
    partial.registerMigration(
      "v4_rate_cache_without_rowid", migrate: ProfileSchema.rebuildRateCacheMetaWithoutRowid)
    partial.registerMigration(
      "v5_drop_foreign_keys", migrate: ProfileSchema.dropForeignKeys)
    partial.registerMigration(
      "v6_account_valuation_mode", migrate: ProfileSchema.addAccountValuationMode)
    partial.registerMigration(
      "v7_purge_intraday_cached_prices", migrate: ProfileSchema.purgeIntradayCachedPrices)
    partial.registerMigration(
      "v8_add_crypto_wallet_fields", migrate: ProfileSchema.addCryptoWalletFields)
    partial.registerMigration(
      "v9_add_counterparty_address",
      migrate: ProfileSchema.addCounterpartyAddressToTransactionLeg)
    try partial.migrate(queue)
    return queue
  }

  /// Inserts one row in every core-graph table plus seed rows in the
  /// soon-to-be-dropped legacy tables so the migration is exercised
  /// against non-empty tables.
  private func seedV9Rows(into queue: DatabaseQueue) throws {
    let ids = SeedIds()
    try queue.write { database in
      try Self.seedLegacyTables(database)
    }
    try queue.write { database in
      try Self.seedCoreGraph(database, ids: ids)
    }
  }

  /// UUIDs shared between the two seed closures.
  private struct SeedIds {
    let account = UUID()
    let category = UUID()
    let parentCategory = UUID()
    let earmark = UUID()
    let budget = UUID()
    let transaction = UUID()
    let leg = UUID()
    let investment = UUID()
  }

  /// Seeds one row in each of the seven soon-to-be-dropped tables so
  /// the migration runs against non-empty tables.
  private static func seedLegacyTables(_ database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO instrument (id, record_name, kind, name, decimals)
          VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
        INSERT INTO exchange_rate (base, quote, date, rate)
          VALUES ('USD', 'EUR', '2026-01-01', 0.9);
        INSERT INTO exchange_rate_meta (base, earliest_date, latest_date)
          VALUES ('USD', '2026-01-01', '2026-01-01');
        INSERT INTO stock_price (ticker, date, price)
          VALUES ('AAPL', '2026-01-01', 19000);
        INSERT INTO stock_ticker_meta (ticker, instrument_id, earliest_date, latest_date)
          VALUES ('AAPL', 'AAPL', '2026-01-01', '2026-01-01');
        INSERT INTO crypto_price (token_id, date, price_usd)
          VALUES ('bitcoin', '2026-01-01', 6500000);
        INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
          VALUES ('bitcoin', 'BTC', '2026-01-01', '2026-01-01');
        """)
  }

  /// Seeds one row in every core-graph table that must survive v10.
  private static func seedCoreGraph(_ database: Database, ids: SeedIds) throws {
    try database.execute(
      sql: """
        INSERT INTO category (id, record_name, name, parent_id)
          VALUES (?, 'category-parent', 'Parent', NULL);
        INSERT INTO category (id, record_name, name, parent_id)
          VALUES (?, 'category-child', 'Child', ?);
        INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden)
          VALUES (?, 'account-1', 'Checking', 'bank', 'USD', 0, 0);
        INSERT INTO earmark (id, record_name, name, position, is_hidden)
          VALUES (?, 'earmark-1', 'Holiday', 0, 0);
        INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
          VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
        INSERT INTO "transaction" (id, record_name, date)
          VALUES (?, 'tx-1', '2026-01-01');
        INSERT INTO transaction_leg (id, record_name, transaction_id, account_id, instrument_id,
                                     quantity, type, category_id, earmark_id, sort_order)
          VALUES (?, 'leg-1', ?, ?, 'USD', 1234, 'expense', ?, ?, 0);
        INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id)
          VALUES (?, 'iv-1', ?, '2026-01-01', 100000, 'USD');
        """,
      arguments: [
        ids.parentCategory, ids.category, ids.parentCategory, ids.account,
        ids.earmark, ids.budget, ids.earmark, ids.category, ids.transaction,
        ids.leg, ids.transaction, ids.account, ids.category, ids.earmark,
        ids.investment, ids.account,
      ])
  }
}
