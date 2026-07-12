// MoolahTests/Backends/GRDB/AccountValuationModeMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v6_account_valuation_mode migration")
struct AccountValuationModeMigrationTests {
  @Test("column exists on the account table after migration")
  func columnExists() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v6_account_valuation_mode")
    try queue.read { database in
      let columns = try database.columns(in: "account")
      #expect(columns.contains { $0.name == "valuation_mode" })
    }
  }

  @Test("CHECK constraint rejects unknown raw values")
  func checkConstraintRejectsBadValues() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v6_account_valuation_mode")
    try queue.write { database in
      do {
        try database.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position,
               is_hidden, valuation_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            Data(repeating: 1, count: 16), "AccountRecord|y", "B",
            "investment", "AUD", 0, 0, "garbage",
          ])
        Issue.record("Expected CHECK constraint failure")
      } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
      }
    }
  }

  @Test("INSERT omitting valuation_mode column receives DEFAULT recordedValue")
  func newRowWithoutValuationModeGetsDefault() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v6_account_valuation_mode")
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account
            (id, record_name, name, type, instrument_id, position, is_hidden)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(repeating: 0, count: 16), "AccountRecord|x", "B",
          "investment", "AUD", 0, 0,
        ])
    }
    let mode: String? = try queue.read { database in
      try String.fetchOne(database, sql: "SELECT valuation_mode FROM account")
    }
    #expect(mode == "recordedValue")
  }
}
