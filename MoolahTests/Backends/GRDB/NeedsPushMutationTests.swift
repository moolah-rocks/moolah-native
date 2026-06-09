import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("needs_push column migration")
struct NeedsPushMutationTests {
  private static let tables = [
    "account", "account_group", "category", "earmark", "earmark_budget_item",
    "investment_value", "\"transaction\"", "transaction_leg", "transfer_suggestion",
    "insight_dismissal", "csv_import_profile", "import_rule",
  ]

  @Test("every syncable table has needs_push INTEGER NOT NULL DEFAULT 0")
  func needsPushColumnPresent() throws {
    let database = try ProfileDatabase.openInMemory()
    try database.read { database in
      for table in Self.tables {
        let unquoted = table.replacingOccurrences(of: "\"", with: "")
        let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
        let needsPush = columns.first { ($0["name"] as String?) == "needs_push" }
        let col = try #require(needsPush, "needs_push missing on \(unquoted)")
        #expect((col["notnull"] as Int?) == 1)
        #expect((col["dflt_value"] as String?) == "0")
      }
    }
  }

  @Test("profile table has needs_push INTEGER NOT NULL DEFAULT 0")
  func profileNeedsPushColumnPresent() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try database.read { database in
      let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(profile)")
      let needsPush = columns.first { ($0["name"] as String?) == "needs_push" }
      let col = try #require(needsPush, "needs_push missing on profile")
      #expect((col["notnull"] as Int?) == 1)
      #expect((col["dflt_value"] as String?) == "0")
    }
  }

  @Test("markNeedsPushSync sets the flag; dirtyIdsSync reports it; clear resets it")
  func markReadClearRoundTrip() throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database, instrumentResolver: registry, instrumentRegistrar: registry)
    let id = UUID()
    try database.write { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A").insert(database)
    }

    #expect(try repo.dirtyIdsSync(from: [id]).isEmpty)

    try database.write { database in try repo.markNeedsPushSync(id: id, in: database) }
    #expect(try repo.dirtyIdsSync(from: [id]) == [id])

    _ = try repo.clearNeedsPushBatchSync([id])
    #expect(try repo.dirtyIdsSync(from: [id]).isEmpty)
  }

  @Test("account create/update set needs_push")
  func accountMutationsMarkDirty() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database, instrumentResolver: registry, instrumentRegistrar: registry)
    let account = Account(
      id: UUID(), name: "Checking", type: .bank,
      instrument: .defaultTestInstrument, position: 0)

    _ = try await repo.create(account)
    #expect(try repo.dirtyIdsSync(from: [account.id]) == [account.id])

    _ = try repo.clearNeedsPushBatchSync([account.id])
    var renamed = account
    renamed.name = "Renamed"
    _ = try await repo.update(renamed)
    #expect(try repo.dirtyIdsSync(from: [account.id]) == [account.id])
  }
}
