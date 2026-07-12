import Foundation
import GRDB
import Testing

@testable import Moolah

struct ExchangeAccountMigrationTests {
  private let id = Data(repeating: 1, count: 16)

  private func migratorThroughV10() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_initial", migrate: ProfileSchema.createInitialTables)
    migrator.registerMigration(
      "v2_csv_import_and_rules", migrate: ProfileSchema.createCSVImportAndRulesTables)
    migrator.registerMigration(
      "v3_core_financial_graph", migrate: ProfileSchema.createCoreFinancialGraphTables)
    migrator.registerMigration(
      "v4_rate_cache_without_rowid", migrate: ProfileSchema.rebuildRateCacheMetaWithoutRowid)
    migrator.registerMigration("v5_drop_foreign_keys", migrate: ProfileSchema.dropForeignKeys)
    migrator.registerMigration(
      "v6_account_valuation_mode", migrate: ProfileSchema.addAccountValuationMode)
    migrator.registerMigration(
      "v7_purge_intraday_cached_prices", migrate: ProfileSchema.purgeIntradayCachedPrices)
    migrator.registerMigration(
      "v8_add_crypto_wallet_fields", migrate: ProfileSchema.addCryptoWalletFields)
    migrator.registerMigration(
      "v9_add_counterparty_address",
      migrate: ProfileSchema.addCounterpartyAddressToTransactionLeg)
    migrator.registerMigration(
      "v10_drop_shared_instrument_legacy", migrate: ProfileSchema.dropSharedInstrumentLegacy)
    return migrator
  }

  @Test
  func v11AllowsExchangeTypeAndStoresProvider() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v11_add_exchange_account_fields")
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account (id, record_name, name, type, instrument_id,
            position, is_hidden, valuation_mode, exchange_provider)
          VALUES (?, 'rec', 'Coinstash', 'exchange', 'AUD', 0, 0,
            'calculatedFromTrades', 'coinstash')
          """,
        arguments: [id])
    }
    let provider = try queue.read { database in
      try String.fetchOne(
        database, sql: "SELECT exchange_provider FROM account WHERE type = 'exchange'")
    }
    #expect(provider == "coinstash")
  }

  @Test
  func v11RejectsUnknownExchangeProvider() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v11_add_exchange_account_fields")
    do {
      try queue.write { database in
        try database.execute(
          sql: """
            INSERT INTO account (id, record_name, name, type, instrument_id,
              position, is_hidden, valuation_mode, exchange_provider)
            VALUES (?, 'rec2', 'X', 'exchange', 'AUD', 0, 0,
              'calculatedFromTrades', 'not-a-provider')
            """,
          arguments: [Data(repeating: 2, count: 16)])
      }
      Issue.record("Expected CHECK constraint failure")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
  }

  @Test
  func v11RollsBackOnFailureLeavingSchemaIntact() throws {
    let queue = try DatabaseQueue()
    try migratorThroughV10().migrate(queue)
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account (id, record_name, name, type, instrument_id,
            position, is_hidden, valuation_mode)
          VALUES (?, 'keep', 'Keep', 'bank', 'AUD', 0, 0, 'recordedValue')
          """,
        arguments: [id])
      try database.execute(
        sql: """
          INSERT INTO account (id, record_name, name, type, instrument_id,
            position, is_hidden, valuation_mode, wallet_address, chain_id)
          VALUES (?, 'wallet', 'Wallet', 'crypto', 'ETH', 1, 0, 'recordedValue', '0xabc', 1)
          """,
        arguments: [Data(repeating: 3, count: 16)])
    }
    #expect(throws: (any Error).self) {
      try queue.write { database in
        try ProfileSchema.addExchangeAccountFields(database)
        throw CancellationError()
      }
    }
    try queue.read { database in
      let keepCount = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM account WHERE record_name = 'keep'")
      #expect(keepCount == 1)
      let accountNewExists = try Bool.fetchOne(
        database, sql: "SELECT 1 FROM sqlite_master WHERE name = 'account_new'")
      #expect(accountNewExists == nil)
      let columnNames = try database.columns(in: "account").map(\.name)
      #expect(!columnNames.contains("exchange_provider"))
      let walletAddress = try String.fetchOne(
        database, sql: "SELECT wallet_address FROM account WHERE record_name = 'wallet'")
      #expect(walletAddress == "0xabc")
      let chainId = try Int.fetchOne(
        database, sql: "SELECT chain_id FROM account WHERE record_name = 'wallet'")
      #expect(chainId == 1)
    }
  }
}
