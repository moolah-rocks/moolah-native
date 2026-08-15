import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema sync mutation tokens")
struct SyncMutationTokenMigrationTests {
  private static let tables = [
    "tax_owner", "category", "account_group", "insight_dismissal",
    "wallet_sync_checkpoint", "account", "earmark", "earmark_budget_item",
    "transaction", "transaction_leg", "csv_import_profile", "import_rule",
    "transfer_suggestion",
  ]

  private func withDiskQueue(_ body: (DatabaseQueue) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-token-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(try DatabaseQueue(path: directory.appendingPathComponent("profile.sqlite").path))
  }

  @Test("v29 upgrades populated data and installs every token trigger")
  func upgradesPopulatedV28() throws {
    try withDiskQueue { queue in
      try ProfileSchema.migrator.migrate(queue, upTo: "v28_account_automatic_sync")
      let id = UUID()
      try queue.write { database in
        try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Existing")
          .insert(database)
      }

      try ProfileSchema.migrator.migrate(queue)

      try queue.read { database in
        for table in Self.tables {
          #expect(
            try database.columns(in: table).contains { $0.name == "local_mutation_token" },
            "missing token column on \(table)")
        }
        let triggers = try Set(
          String.fetchAll(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        for table in Self.tables {
          #expect(triggers.contains("\(table)_refresh_sync_token"))
        }
        let token = try String.fetchOne(
          database,
          sql: "SELECT local_mutation_token FROM account WHERE id = ?",
          arguments: [id])
        #expect(token?.isEmpty == true)
      }
    }
  }

  @Test("every repeated edit receives a distinct token")
  func tokensDistinguishAba() throws {
    let queue = try ProfileDatabase.openInMemory()
    let id = UUID()
    let row = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A")
    let tokens = try queue.write { database -> [String] in
      try row.insert(database)
      var result: [String] = []
      for name in ["A", "B", "A"] {
        try database.execute(
          sql: "UPDATE account SET name = ?, needs_push = 1 WHERE id = ?",
          arguments: [name, id])
        let token = try String.fetchOne(
          database,
          sql: "SELECT local_mutation_token FROM account WHERE id = ?",
          arguments: [id])
        result.append(try #require(token))
      }
      return result
    }
    #expect(Set(tokens).count == tokens.count)
    #expect(tokens.allSatisfy { $0.count == 32 })
  }

  @Test("batch token lookup uses each table's primary-key index")
  func tokenLookupPlansArePinned() throws {
    let queue = try ProfileDatabase.openInMemory()
    try queue.read { database in
      for table in Self.tables {
        let request: SQLRequest<Row> = """
          EXPLAIN QUERY PLAN
          SELECT id, local_mutation_token
          FROM \(identifier: table)
          WHERE id IN \([UUID(), UUID()])
          """
        let details = try request.fetchAll(database).map {
          String(describing: $0["detail"] ?? "")
        }
        #expect(
          details.contains { $0.contains("SEARCH \(table)") },
          "token lookup must use an indexed search for \(table): \(details)")
        #expect(!details.contains { $0.contains("SCAN \(table)") })
      }
    }
  }

  @Test("a late migration failure rolls back every earlier schema change")
  func migrationRollsBackAtomically() throws {
    try withDiskQueue { queue in
      try ProfileSchema.migrator.migrate(queue, upTo: "v28_account_automatic_sync")
      try queue.write { database in
        try database.execute(
          sql:
            "CREATE TRIGGER transfer_suggestion_refresh_sync_token AFTER INSERT ON account BEGIN SELECT 1; END"
        )
      }

      #expect(throws: (any Error).self) {
        try ProfileSchema.migrator.migrate(queue)
      }

      try queue.read { database in
        for table in Self.tables {
          let columns = try database.columns(in: table)
          #expect(
            !columns.contains { $0.name == "local_mutation_token" },
            "partial migration changed \(table)")
        }
        let applied = try Set(
          String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations"))
        #expect(!applied.contains("v29_sync_mutation_token"))
        let triggers = try Set(
          String.fetchAll(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        for table in Self.tables.dropLast() {
          #expect(!triggers.contains("\(table)_refresh_sync_token"))
        }
      }
    }
  }
}
