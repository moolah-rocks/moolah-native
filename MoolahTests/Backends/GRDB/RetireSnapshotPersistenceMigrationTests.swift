import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v25_retire_investment_value_persistence migration")
struct RetireSnapshotPersistenceMigrationTests {
  @Test(arguments: [0, 1, 7])
  func queuesEverySnapshotDeletionAndDropsRetiredSchema(snapshotCount: Int) throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v24_trade_only_valuation")
    let accountId = UUID()
    let snapshotIds = (0..<snapshotCount).map { _ in UUID() }

    try queue.write { database in
      try seedAccount(id: accountId, in: database)
      for id in snapshotIds {
        try database.execute(
          sql: """
            INSERT INTO investment_value
              (id, record_name, account_id, date, value, instrument_id,
               encoded_system_fields, needs_push)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, "InvestmentValueRecord|\(id.uuidString)", accountId,
            Date(timeIntervalSince1970: 1_700_000_000), 42, "AUD", Data([1, 2, 3]), true,
          ])
      }
    }

    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      #expect(try tableExists("investment_value", in: database) == false)
      #expect(
        try columnNames(in: "account", database: database).contains("valuation_mode") == false)
      let journal = try Row.fetchAll(
        database,
        sql: """
          SELECT zone_name, record_name, record_type
          FROM deletion_journal
          WHERE record_type = 'InvestmentValueRecord'
          ORDER BY record_name
          """)
      #expect(journal.count == snapshotCount)
      #expect(
        journal.map { $0["zone_name"] as String }
          == Array(repeating: "@profile-data", count: snapshotCount))
      #expect(
        Set(journal.map { $0["record_name"] as String })
          == Set(snapshotIds.map { "InvestmentValueRecord|\($0.uuidString)" }))
    }
  }

  @Test("account column drop preserves every retained field, constraint, and index")
  func preservesAccountContract() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v24_trade_only_valuation")
    let id = UUID()
    let groupId = UUID()
    let ownerIds = "[\"\(UUID().uuidString)\"]"
    let systemFields = Data([9, 8, 7])
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account
            (id, record_name, name, type, instrument_id, position, is_hidden,
             valuation_mode, wallet_address, chain_id, exchange_provider,
             encoded_system_fields, group_id, needs_push, tax_owner_ids_encoded)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id, "AccountRecord|\(id.uuidString)", "Preserved", "exchange", "BTC",
          17, true, "calculatedFromTrades", "0xabc", 1, "coinstash", systemFields,
          groupId, true, ownerIds,
        ])
    }

    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      try expectPreservedAccount(
        id: id, groupId: groupId, ownerIds: ownerIds,
        systemFields: systemFields, in: database)
      #expect(throws: (any Error).self) {
        try database.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position, is_hidden, needs_push)
            VALUES (?, ?, '', 'unknown', 'AUD', 0, 0, 0)
            """,
          arguments: [UUID(), "AccountRecord|invalid"])
      }
    }
  }

  @Test("failure rolls back deletion journal and both schema changes")
  func failureRollsBackMigration() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v24_trade_only_valuation")
    let accountId = UUID()
    try queue.write { database in
      try seedAccount(id: accountId, in: database)
      try database.execute(
        sql: """
          INSERT INTO investment_value
            (id, record_name, account_id, date, value, instrument_id, needs_push)
          VALUES (?, 'InvestmentValueRecord|rollback', ?, '2026-01-01', 1, 'AUD', 0);
          CREATE INDEX valuation_mode_dependency ON account(valuation_mode);
          """,
        arguments: [UUID(), accountId])
    }

    #expect(throws: (any Error).self) {
      try ProfileSchema.migrator.migrate(queue)
    }
    try queue.read { database in
      let snapshotTableExists = try tableExists("investment_value", in: database)
      let accountColumns = try columnNames(in: "account", database: database)
      let deletionCount = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM deletion_journal")
      let snapshotCount = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM investment_value")
      let snapshotIndexCount = try Int.fetchOne(
        database,
        sql: """
          SELECT COUNT(*) FROM sqlite_master
          WHERE type = 'index' AND name = 'iv_by_account_date_value'
          """)
      #expect(snapshotTableExists)
      #expect(accountColumns.contains("valuation_mode"))
      #expect(deletionCount == 0)
      #expect(snapshotCount == 1)
      #expect(snapshotIndexCount == 1)
    }
  }

  private func expectPreservedAccount(
    id: UUID,
    groupId: UUID,
    ownerIds: String,
    systemFields: Data,
    in database: Database
  ) throws {
    let row = try #require(try Row.fetchOne(database, sql: "SELECT * FROM account"))
    #expect(row["id"] as UUID == id)
    #expect(row["record_name"] as String == "AccountRecord|\(id.uuidString)")
    #expect(row["name"] as String == "Preserved")
    #expect(row["type"] as String == "exchange")
    #expect(row["instrument_id"] as String == "BTC")
    #expect(row["position"] as Int == 17)
    #expect(row["is_hidden"] as Bool)
    #expect(row["wallet_address"] as String? == "0xabc")
    #expect(row["chain_id"] as Int? == 1)
    #expect(row["exchange_provider"] as String? == "coinstash")
    #expect(row["encoded_system_fields"] as Data? == systemFields)
    #expect(row["group_id"] as UUID? == groupId)
    #expect(row["needs_push"] as Bool)
    #expect(row["tax_owner_ids_encoded"] as String? == ownerIds)
    #expect(
      Set(
        try String.fetchAll(
          database,
          sql:
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'account' AND name NOT LIKE 'sqlite_%'"
        ))
        == ["account_by_position", "account_by_type", "account_by_group_id"])

  }

  private func seedAccount(id: UUID, in database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO account
          (id, record_name, name, type, instrument_id, position, is_hidden,
           valuation_mode, needs_push)
        VALUES (?, ?, 'Brokerage', 'investment', 'AUD', 0, 0,
                'calculatedFromTrades', 0)
        """,
      arguments: [id, "AccountRecord|\(id.uuidString)"])
  }

  private func tableExists(_ name: String, in database: Database) throws -> Bool {
    try Int.fetchOne(
      database,
      sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
      arguments: [name]) == 1
  }

  private func columnNames(in table: String, database: Database) throws -> Set<String> {
    Set(try database.columns(in: table).map(\.name))
  }
}
