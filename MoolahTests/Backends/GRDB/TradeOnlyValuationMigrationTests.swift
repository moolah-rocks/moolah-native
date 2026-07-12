import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v24_trade_only_valuation migration")
struct TradeOnlyValuationMigrationTests {
  @Test("converts every account without changing transactions, positions, or snapshots")
  func convertsEveryAccountWithoutChangingFinancialData() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v23_tax_reporting")

    let snapshotId = try seedFinancialGraph(in: queue)

    let snapshotBefore = try snapshotRow(id: snapshotId, from: queue)
    let financialGraphBefore = try financialGraphRows(from: queue)
    try ProfileSchema.migrator.migrate(queue)

    let modes = try queue.read { database in
      try String.fetchAll(
        database,
        sql: "SELECT valuation_mode FROM account ORDER BY name")
    }
    #expect(modes == ["calculatedFromTrades", "calculatedFromTrades"])
    #expect(try snapshotRow(id: snapshotId, from: queue) == snapshotBefore)
    #expect(try financialGraphRows(from: queue) == financialGraphBefore)
  }

  private func seedFinancialGraph(in queue: DatabaseQueue) throws -> UUID {
    let recordedAccountId = UUID()
    let snapshotId = UUID()
    try queue.write { database in
      try insertAccount(
        id: recordedAccountId,
        name: "Recorded",
        type: "investment",
        valuationMode: "recordedValue",
        database: database)
      try insertAccount(
        id: UUID(),
        name: "Trade",
        type: "bank",
        valuationMode: "calculatedFromTrades",
        database: database)
      try insertSnapshot(id: snapshotId, accountId: recordedAccountId, database: database)
      let transactionId = UUID()
      try insertTransaction(id: transactionId, database: database)
      try insertLeg(transactionId: transactionId, accountId: recordedAccountId, database: database)
    }
    return snapshotId
  }

  private func insertAccount(
    id: UUID,
    name: String,
    type: String,
    valuationMode: String,
    database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO account
          (id, record_name, name, type, instrument_id, position,
           is_hidden, valuation_mode, needs_push)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id,
        AccountRow.recordName(for: id),
        name,
        type,
        "AUD",
        0,
        false,
        valuationMode,
        true,
      ])
  }

  private func snapshotRow(
    id: UUID,
    from queue: DatabaseQueue
  ) throws -> [String] {
    try queue.read { database in
      let row = try #require(
        try Row.fetchOne(
          database,
          sql: """
            SELECT id, record_name, account_id, date, value, instrument_id, needs_push
            FROM investment_value
            WHERE id = ?
            """,
          arguments: [id]))
      let snapshotId: UUID = row["id"]
      let recordName: String = row["record_name"]
      let accountId: UUID = row["account_id"]
      let date: Date = row["date"]
      let value: Int64 = row["value"]
      let instrumentId: String = row["instrument_id"]
      let needsPush: Bool = row["needs_push"]
      return [
        snapshotId.uuidString,
        recordName,
        accountId.uuidString,
        String(date.timeIntervalSinceReferenceDate),
        String(value),
        instrumentId,
        String(needsPush),
      ]
    }
  }

  private func insertSnapshot(id: UUID, accountId: UUID, database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO investment_value
          (id, record_name, account_id, date, value, instrument_id, needs_push)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id, InvestmentValueRow.recordName(for: id), accountId,
        Date(timeIntervalSince1970: 1_700_000_000), 12_345, "AUD", true,
      ])
  }

  private func insertTransaction(id: UUID, database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO "transaction" (id, record_name, date, payee, notes, needs_push)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id, TransactionRow.recordName(for: id), Date(timeIntervalSince1970: 1_700_000_100),
        "Opening position", "preserve me", true,
      ])
  }

  private func insertLeg(transactionId: UUID, accountId: UUID, database: Database) throws {
    let id = UUID()
    try database.execute(
      sql: """
        INSERT INTO transaction_leg
          (id, record_name, transaction_id, account_id, instrument_id,
           quantity, type, sort_order, needs_push)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id, TransactionLegRow.recordName(for: id), transactionId, accountId,
        "AUD", 500_000_000, "openingBalance", 0, true,
      ])
  }

  private func financialGraphRows(from queue: DatabaseQueue) throws -> [[String]] {
    try queue.read { database in
      let transactionRows = try Row.fetchAll(
        database,
        sql: """
          SELECT id, record_name, date, payee, notes, needs_push
          FROM "transaction" ORDER BY record_name
          """)
      let legRows = try Row.fetchAll(
        database,
        sql: """
          SELECT id, record_name, transaction_id, account_id, instrument_id,
                 quantity, type, sort_order, needs_push
          FROM transaction_leg ORDER BY record_name
          """)
      return encodeTransactionRows(transactionRows) + encodeLegRows(legRows)
    }
  }

  private func encodeTransactionRows(_ rows: [Row]) -> [[String]] {
    rows.map { row in
      let id: UUID = row["id"]
      let recordName: String = row["record_name"]
      let date: Date = row["date"]
      let payee: String? = row["payee"]
      let notes: String? = row["notes"]
      let needsPush: Bool = row["needs_push"]
      return [
        "transaction", id.uuidString, recordName,
        String(date.timeIntervalSinceReferenceDate), payee ?? "", notes ?? "", String(needsPush),
      ]
    }
  }

  private func encodeLegRows(_ rows: [Row]) -> [[String]] {
    rows.map { row in
      let id: UUID = row["id"]
      let recordName: String = row["record_name"]
      let transactionId: UUID = row["transaction_id"]
      let accountId: UUID? = row["account_id"]
      let instrumentId: String = row["instrument_id"]
      let quantity: Int64 = row["quantity"]
      let type: String = row["type"]
      let sortOrder: Int = row["sort_order"]
      let needsPush: Bool = row["needs_push"]
      return [
        "leg", id.uuidString, recordName, transactionId.uuidString,
        accountId?.uuidString ?? "", instrumentId, String(quantity), type,
        String(sortOrder), String(needsPush),
      ]
    }
  }
}
