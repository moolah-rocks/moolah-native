import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("needs_push column migration")
struct NeedsPushMutationTests {
  /// Asserts the `needs_push` column on the table described by `pragmaRows`
  /// is `INTEGER NOT NULL DEFAULT 0`. The caller fetches `pragmaRows` via
  /// an explicit per-table literal `PRAGMA table_info(...)` (no string
  /// interpolation); `unquoted` names the table in failure messages.
  private func expectNeedsPushColumn(
    pragmaRows: [Row], unquoted: String
  ) throws {
    let needsPush = pragmaRows.first { ($0["name"] as String?) == "needs_push" }
    let col = try #require(needsPush, "needs_push missing on \(unquoted)")
    #expect((col["notnull"] as Int?) == 1)
    #expect((col["dflt_value"] as String?) == "0")
  }

  @Test("every syncable table has needs_push INTEGER NOT NULL DEFAULT 0")
  func needsPushColumnPresent() throws {
    let database = try ProfileDatabase.openInMemory()
    // Explicit per-table literal PRAGMA calls (no `\(table)` interpolation)
    // so a failure points at the exact table and the SQL is a literal.
    try assertReferenceTablesHaveNeedsPush(database)
    try assertDomainTablesHaveNeedsPush(database)
  }

  private func assertReferenceTablesHaveNeedsPush(_ database: DatabaseQueue) throws {
    try database.read { database in
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(account_group)"),
        unquoted: "account_group")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(category)"),
        unquoted: "category")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(transfer_suggestion)"),
        unquoted: "transfer_suggestion")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(insight_dismissal)"),
        unquoted: "insight_dismissal")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(csv_import_profile)"),
        unquoted: "csv_import_profile")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(import_rule)"),
        unquoted: "import_rule")
    }
  }

  private func assertDomainTablesHaveNeedsPush(_ database: DatabaseQueue) throws {
    try database.read { database in
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(account)"),
        unquoted: "account")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(earmark)"),
        unquoted: "earmark")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(earmark_budget_item)"),
        unquoted: "earmark_budget_item")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(investment_value)"),
        unquoted: "investment_value")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(\"transaction\")"),
        unquoted: "transaction")
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(transaction_leg)"),
        unquoted: "transaction_leg")
    }
  }

  @Test("needs_push CHECK rejects values outside 0/1 on a syncable table")
  func needsPushCheckConstraintEnforced() throws {
    let database = try ProfileDatabase.openInMemory()
    let id = UUID()
    try database.write { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "A").insert(database)
    }
    // `needs_push` is local-only (absent from AccountRow's CodingKeys), so
    // drive the CHECK with a literal UPDATE rather than the query builder.
    #expect(throws: DatabaseError.self) {
      try database.write { database in
        try database.execute(
          sql: "UPDATE account SET needs_push = 2 WHERE id = ?", arguments: [id])
      }
    }
  }

  @Test("profile table has needs_push INTEGER NOT NULL DEFAULT 0")
  func profileNeedsPushColumnPresent() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try database.read { database in
      try expectNeedsPushColumn(
        pragmaRows: Row.fetchAll(database, sql: "PRAGMA table_info(profile)"),
        unquoted: "profile")
    }
  }

  @Test("needs_push CHECK rejects values outside 0/1 on the profile table")
  func profileNeedsPushCheckConstraintEnforced() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let profile = Profile(
      id: UUID(), label: "P", currencyCode: "AUD", financialYearStartMonth: 7)
    try database.write { database in
      try ProfileRow(domain: profile).insert(database)
    }
    #expect(throws: DatabaseError.self) {
      try database.write { database in
        try database.execute(
          sql: "UPDATE profile SET needs_push = -1 WHERE id = ?", arguments: [profile.id])
      }
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
