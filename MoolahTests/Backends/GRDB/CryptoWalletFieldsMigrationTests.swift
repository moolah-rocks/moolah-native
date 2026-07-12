// MoolahTests/Backends/GRDB/CryptoWalletFieldsMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v8_add_crypto_wallet_fields migration")
struct CryptoWalletFieldsMigrationTests {
  @Test("account gains wallet_address and chain_id; type CHECK accepts crypto")
  func accountColumnsAndCheck() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v8_add_crypto_wallet_fields")
    try queue.read { database in
      let columns = try database.columns(in: "account").map(\.name)
      #expect(columns.contains("wallet_address"))
      #expect(columns.contains("chain_id"))
    }
    // INSERT with type='crypto' must succeed.
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account
            (id, record_name, name, type, instrument_id, position, is_hidden,
             valuation_mode, wallet_address, chain_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(repeating: 1, count: 16), "AccountRecord|crypto1", "Wallet",
          "crypto", "ETH-NATIVE", 0, 0, "recordedValue",
          "0x1111111111111111111111111111111111111111", 1,
        ])
    }
  }

  @Test("account.type CHECK still rejects unknown values")
  func accountTypeCheckRejectsUnknown() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v8_add_crypto_wallet_fields")
    try queue.write { database in
      do {
        try database.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position, is_hidden, valuation_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            Data(repeating: 2, count: 16), "AccountRecord|x", "X",
            "future-account-type", "AUD", 0, 0, "recordedValue",
          ])
        Issue.record("Expected CHECK constraint failure")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("transaction_leg gains external_id with partial-unique dedup index")
  func transactionLegExternalIdAndIndex() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v8_add_crypto_wallet_fields")
    try queue.read { database in
      let columns = try database.columns(in: "transaction_leg").map(\.name)
      #expect(columns.contains("external_id"))
      let indexes = try database.indexes(on: "transaction_leg").map(\.name)
      #expect(indexes.contains("leg_dedup_by_account_external"))
    }
  }

  @Test("partial unique index rejects duplicate (account_id, external_id)")
  func dedupIndexRejectsDuplicate() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v8_add_crypto_wallet_fields")
    let accountId = Data(repeating: 7, count: 16)
    try queue.write { database in
      try Self.seedAccountAndTransaction(database, accountId: accountId)
      try Self.insertLeg(
        database, LegSeed(id: 9, accountId: accountId, externalId: "0xabc", quantity: 1000))
      do {
        try Self.insertLeg(
          database, LegSeed(id: 10, accountId: accountId, externalId: "0xabc", quantity: 500))
        Issue.record("Expected UNIQUE constraint failure for duplicate (account, externalId)")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("partial unique index allows multiple NULL externalIds on same account")
  func dedupIndexAllowsMultipleNulls() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v8_add_crypto_wallet_fields")
    let accountId = Data(repeating: 7, count: 16)
    try queue.write { database in
      try Self.seedAccountAndTransaction(database, accountId: accountId)
      try Self.insertLeg(
        database, LegSeed(id: 11, accountId: accountId, externalId: nil, quantity: 200))
      try Self.insertLeg(
        database, LegSeed(id: 12, accountId: accountId, externalId: nil, quantity: 300))
    }
  }

  // MARK: - Helpers

  private struct LegSeed {
    let id: UInt8
    let accountId: Data
    let externalId: String?
    let quantity: Int
    /// All test legs in this suite roll up under the same seeded transaction
    /// (`Data(repeating: 8, count: 16)`) so dedup is verified at the leg
    /// level, not skewed by transaction-id mismatches.
    var transactionId: Data { Data(repeating: 8, count: 16) }
  }

  private static func seedAccountAndTransaction(
    _ database: Database, accountId: Data
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO account
          (id, record_name, name, type, instrument_id, position, is_hidden, valuation_mode)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        accountId, "AccountRecord|dedup", "Dedup",
        "investment", "AUD", 0, 0, "recordedValue",
      ])
    try database.execute(
      sql: "INSERT INTO \"transaction\" (id, record_name, date, payee) VALUES (?, ?, ?, ?)",
      arguments: [Data(repeating: 8, count: 16), "TxnRecord|d", "2024-01-01", ""])
  }

  private static func insertLeg(_ database: Database, _ seed: LegSeed) throws {
    if let externalId = seed.externalId {
      try database.execute(
        sql: """
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, account_id, instrument_id,
             quantity, type, sort_order, external_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(repeating: seed.id, count: 16), "LegRecord|\(seed.id)",
          seed.transactionId, seed.accountId, "AUD",
          seed.quantity, "income", 0, externalId,
        ])
    } else {
      try database.execute(
        sql: """
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, account_id, instrument_id,
             quantity, type, sort_order)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(repeating: seed.id, count: 16), "LegRecord|\(seed.id)",
          seed.transactionId, seed.accountId, "AUD",
          seed.quantity, "income", 0,
        ])
    }
  }

  @Test("instrument gains pricing_status with priced default and CHECK constraint")
  func instrumentPricingStatusColumn() throws {
    let queue = try DatabaseQueue()
    // Pinned to the v8 era: `v10_drop_shared_instrument_legacy` later
    // drops the per-profile `instrument` table, so this column's
    // contract is only observable at the migration that added it.
    try ProfileSchema.migrator.migrate(queue, upTo: "v8_add_crypto_wallet_fields")
    try queue.read { database in
      let columns = try database.columns(in: "instrument").map(\.name)
      #expect(columns.contains("pricing_status"))
    }
    // INSERT without pricing_status — receives DEFAULT 'priced'.
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument
            (id, record_name, kind, name, decimals)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: ["TEST-DEFAULT", "InstrumentRecord|defaultpriced", "fiatCurrency", "Test", 2])
    }
    let status: String? = try queue.read { database in
      try String.fetchOne(
        database, sql: "SELECT pricing_status FROM instrument WHERE id = 'TEST-DEFAULT'")
    }
    #expect(status == "priced")
    // CHECK constraint rejects bad values.
    try queue.write { database in
      do {
        try database.execute(
          sql: """
            INSERT INTO instrument
              (id, record_name, kind, name, decimals, pricing_status)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: ["TEST-BAD", "InstrumentRecord|bad", "fiatCurrency", "Bad", 2, "garbage"])
        Issue.record("Expected CHECK constraint failure")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("wallet_sync_state table exists with STRICT and json_valid CHECK")
  func walletSyncStateTable() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      #expect(try database.tableExists("wallet_sync_state"))
      let columns = try database.columns(in: "wallet_sync_state").map(\.name)
      #expect(columns.contains("account_id"))
      #expect(columns.contains("last_synced_block_number"))
      #expect(columns.contains("last_synced_at"))
      #expect(columns.contains("last_error_json"))
      // STRICT: confirm via sqlite_master DDL.
      let createSQL: String? = try String.fetchOne(
        database,
        sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='wallet_sync_state'")
      let sqlText = try #require(createSQL)
      #expect(sqlText.uppercased().contains("STRICT"))
    }
    // Valid JSON in last_error_json — accepted.
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO wallet_sync_state
            (account_id, last_synced_block_number, last_synced_at, last_error_json)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [Data(repeating: 13, count: 16), 100, "2024-01-01T00:00:00Z", "{\"foo\":1}"])
    }
    // Invalid JSON — rejected.
    try queue.write { database in
      do {
        try database.execute(
          sql: """
            INSERT INTO wallet_sync_state
              (account_id, last_synced_block_number, last_synced_at, last_error_json)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [Data(repeating: 14, count: 16), 100, "2024-01-01T00:00:00Z", "not json"])
        Issue.record("Expected json_valid CHECK to reject")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("existing account indexes survive table rebuild")
  func accountIndexesPreserved() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      let indexes = try database.indexes(on: "account").map(\.name)
      #expect(indexes.contains("account_by_position"))
      #expect(indexes.contains("account_by_type"))
    }
  }
}
