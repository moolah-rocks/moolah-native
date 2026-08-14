import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v28 account automatic sync migration")
struct ProfileSchemaAutomaticSyncTests {
  @Test("Existing accounts keep automatic sync enabled")
  func existingAccountsDefaultToEnabled() throws {
    let database = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(database, upTo: "v27_insight_display_history")
    let id = UUID()
    try database.write { database in
      try database.execute(
        sql: """
          INSERT INTO account (
              id, record_name, name, type, instrument_id, position, is_hidden
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id, AccountRow.recordName(for: id), "Savings", "bank", "AUD", 0, false,
        ])
    }

    try ProfileSchema.migrator.migrate(database)

    let enabled = try database.read { database in
      try Bool.fetchOne(
        database,
        sql: "SELECT is_automatic_sync_enabled FROM account WHERE id = ?",
        arguments: [id])
    }
    #expect(enabled == true)
  }

  @Test("Automatic sync accepts only Boolean storage values")
  func automaticSyncRejectsInvalidStorage() throws {
    let database = try ProfileDatabase.openInMemory()
    let id = UUID()
    try database.write { database in
      try AccountRow(
        id: id,
        recordName: AccountRow.recordName(for: id),
        name: "Savings",
        type: AccountType.bank.rawValue,
        instrumentId: Instrument.AUD.id,
        position: 0,
        isHidden: false,
        encodedSystemFields: nil
      ).insert(database)
    }

    #expect(throws: DatabaseError.self) {
      try database.write { database in
        try database.execute(
          sql: "UPDATE account SET is_automatic_sync_enabled = 2 WHERE id = ?",
          arguments: [id])
      }
    }
  }
}
