// MoolahTests/Backends/GRDB/WalletSyncCheckpointMigrationTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v22_wallet_sync_checkpoint migration")
struct WalletSyncCheckpointMigrationTests {
  @Test("wallet_sync_checkpoint table exists with STRICT and the expected columns")
  func walletSyncCheckpointTable() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      #expect(try database.tableExists("wallet_sync_checkpoint"))
      let columns = try database.columns(in: "wallet_sync_checkpoint").map(\.name)
      #expect(columns.contains("id"))
      #expect(columns.contains("record_name"))
      #expect(columns.contains("last_synced_block_number"))
      #expect(columns.contains("encoded_system_fields"))
      #expect(columns.contains("needs_push"))
      // STRICT: confirm via sqlite_master DDL.
      let createSQL = try #require(
        try String.fetchOne(
          database,
          sql: """
            SELECT sql FROM sqlite_master
            WHERE type='table' AND name='wallet_sync_checkpoint'
            """))
      #expect(createSQL.uppercased().contains("STRICT"))
    }
  }

  @Test("needs_push CHECK rejects values other than 0/1")
  func needsPushCheckRejectsBadValues() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.write { database in
      do {
        try database.execute(
          sql: """
            INSERT INTO wallet_sync_checkpoint
              (id, record_name, last_synced_block_number, needs_push)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [
            Data(repeating: 5, count: 16),
            "WalletSyncCheckpointRecord|bad", 100, 2,
          ])
        Issue.record("Expected needs_push CHECK to reject value 2")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("record_name UNIQUE rejects duplicates")
  func recordNameUniqueRejectsDuplicates() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO wallet_sync_checkpoint
            (id, record_name, last_synced_block_number)
          VALUES (?, ?, ?)
          """,
        arguments: [
          Data(repeating: 1, count: 16), "WalletSyncCheckpointRecord|dup", 10,
        ])
      do {
        try database.execute(
          sql: """
            INSERT INTO wallet_sync_checkpoint
              (id, record_name, last_synced_block_number)
            VALUES (?, ?, ?)
            """,
          arguments: [
            Data(repeating: 2, count: 16), "WalletSyncCheckpointRecord|dup", 20,
          ])
        Issue.record("Expected record_name UNIQUE to reject the duplicate")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }
}
