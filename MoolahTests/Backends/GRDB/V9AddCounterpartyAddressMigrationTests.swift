// MoolahTests/Backends/GRDB/V9AddCounterpartyAddressMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Behavioural tests for the v9 migration that adds
/// `transaction_leg.counterparty_address`.
///
/// We exercise the migration through the same `ProfileSchema.migrator`
/// the production code uses (no half-migrated fixture), so the column
/// arrives in the order v9 actually applies it on a fresh DB.
@Suite("v9_add_counterparty_address migration")
struct V9AddCounterpartyAddressMigrationTests {
  @Test("transaction_leg gains counterparty_address column (TEXT, nullable)")
  func transactionLegGainsCounterpartyAddressColumn() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v9_add_counterparty_address")
    try queue.read { database in
      let columns = try database.columns(in: "transaction_leg")
      let counterpartyColumn = try #require(
        columns.first { $0.name == "counterparty_address" })
      #expect(counterpartyColumn.type.uppercased() == "TEXT")
      #expect(counterpartyColumn.isNotNull == false)
    }
  }

  @Test("legacy leg row inserted without counterparty_address reads back nil")
  func legacyLegDecodesWithNilCounterparty() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v9_add_counterparty_address")
    try queue.write { database in
      try Self.seedAccountAndTransaction(database)
      // Insert WITHOUT specifying counterparty_address — simulates a row
      // written by pre-v9 code.
      try database.execute(
        sql: """
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, account_id, instrument_id,
             quantity, type, sort_order)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(repeating: 21, count: 16), "LegRecord|legacy",
          Data(repeating: 8, count: 16), Data(repeating: 7, count: 16),
          "AUD", 100, "income", 0,
        ])
    }
    let value: String? = try queue.read { database in
      try String.fetchOne(
        database,
        sql:
          "SELECT counterparty_address FROM transaction_leg WHERE record_name = 'LegRecord|legacy'"
      )
    }
    #expect(value == nil)
  }

  @Test("counterparty_address round-trips through the table")
  func counterpartyAddressRoundTrips() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v9_add_counterparty_address")
    try queue.write { database in
      try Self.seedAccountAndTransaction(database)
      try database.execute(
        sql: """
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, account_id, instrument_id,
             quantity, type, sort_order, counterparty_address)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(repeating: 22, count: 16), "LegRecord|cp",
          Data(repeating: 8, count: 16), Data(repeating: 7, count: 16),
          "AUD", -100, "transfer", 0,
          "0x2222222222222222222222222222222222222222",
        ])
    }
    let value: String? = try queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT counterparty_address FROM transaction_leg WHERE record_name = 'LegRecord|cp'"
      )
    }
    #expect(value == "0x2222222222222222222222222222222222222222")
  }

  // MARK: - Helpers

  private static func seedAccountAndTransaction(_ database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO account
          (id, record_name, name, type, instrument_id, position, is_hidden, valuation_mode)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        Data(repeating: 7, count: 16), "AccountRecord|cp", "CP",
        "investment", "AUD", 0, 0, "recordedValue",
      ])
    try database.execute(
      sql: "INSERT INTO \"transaction\" (id, record_name, date, payee) VALUES (?, ?, ?, ?)",
      arguments: [Data(repeating: 8, count: 16), "TxnRecord|cp", "2024-01-01", ""])
  }
}
