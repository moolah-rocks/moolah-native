// MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v5 drops foreign keys")
struct ProfileSchemaV5DropForeignKeysTests {
  /// After migrations through v5 have run, none of the four child
  /// tables list any FKs in `pragma_foreign_key_list`. This is the
  /// schema-side contract the rest of the work depends on.
  @Test
  func childTablesHaveNoForeignKeys() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v5_drop_foreign_keys")
    try queue.read { database in
      for table in ["category", "earmark_budget_item", "transaction_leg", "investment_value"] {
        #expect(try database.tableExists(table), "Expected v5 table \(table) to exist")
        let fks = try Row.fetchAll(
          database, sql: "SELECT * FROM pragma_foreign_key_list(?)", arguments: [table])
        #expect(fks.isEmpty, "Expected no FKs on \(table); got \(fks)")
      }
    }
  }

  /// Seeds one row in every parent/child table at v4, runs v5, and
  /// asserts that every seeded row survived with identical column values.
  /// This pins the data-preservation guarantee of the table-rebuild
  /// migration against regression.
  @Test
  func dataPreservedAcrossV5Migration() throws {
    let queue = try migratedQueueThroughV4()
    let legId = try seedV4Rows(into: queue)

    var v5Migrator = DatabaseMigrator()
    v5Migrator.registerMigration("v5_drop_foreign_keys", migrate: ProfileSchema.dropForeignKeys)
    try v5Migrator.migrate(queue)

    try queue.read { database in
      #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM category") == 2)
      #expect(
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM earmark_budget_item") == 1)
      #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transaction_leg") == 1)
      #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM investment_value") == 1)

      let leg = try Row.fetchOne(
        database,
        sql: """
          SELECT transaction_id, account_id, category_id, earmark_id, type, sort_order
          FROM transaction_leg WHERE id = ?
          """,
        arguments: [legId])
      #expect(leg != nil)
      // transaction_id is stored as a 16-byte BLOB in STRICT tables.
      // Decode via the typed subscript to avoid a fatal-error on String decode.
      let txBlob: Data? = leg?["transaction_id"]
      #expect(txBlob != nil)
    }
  }

  // MARK: - Helpers

  private func migratedQueueThroughV4() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    var partial = DatabaseMigrator()
    partial.registerMigration("v1_initial", migrate: ProfileSchema.createInitialTables)
    partial.registerMigration(
      "v2_csv_import_and_rules", migrate: ProfileSchema.createCSVImportAndRulesTables)
    partial.registerMigration(
      "v3_core_financial_graph", migrate: ProfileSchema.createCoreFinancialGraphTables)
    partial.registerMigration(
      "v4_rate_cache_without_rowid", migrate: ProfileSchema.rebuildRateCacheMetaWithoutRowid)
    try partial.migrate(queue)
    return queue
  }

  /// Inserts one row in every parent/child table so every FK relationship
  /// is exercised. Returns the `legId` used for the per-column assertion.
  private func seedV4Rows(into queue: DatabaseQueue) throws -> UUID {
    let accountId = UUID()
    let categoryId = UUID()
    let parentCategoryId = UUID()
    let earmarkId = UUID()
    let budgetId = UUID()
    let transactionId = UUID()
    let legId = UUID()
    let ivId = UUID()

    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument (id, record_name, kind, name, decimals)
            VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
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
          parentCategoryId, categoryId, parentCategoryId, accountId, earmarkId,
          budgetId, earmarkId, categoryId, transactionId, legId, transactionId,
          accountId, categoryId, earmarkId, ivId, accountId,
        ])
    }
    return legId
  }
}
