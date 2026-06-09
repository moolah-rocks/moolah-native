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
    try database.read { db in
      for table in Self.tables {
        let unquoted = table.replacingOccurrences(of: "\"", with: "")
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
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
    try database.read { db in
      let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(profile)")
      let needsPush = columns.first { ($0["name"] as String?) == "needs_push" }
      let col = try #require(needsPush, "needs_push missing on profile")
      #expect((col["notnull"] as Int?) == 1)
      #expect((col["dflt_value"] as String?) == "0")
    }
  }
}
