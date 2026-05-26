import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v14 account groups")
struct ProfileSchemaAccountGroupsTests {
  @Test("creates account_group table and adds group_id column to account")
  func migrates() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      #expect(try database.tableExists("account_group"))

      let accountColumns = try Set(database.columns(in: "account").map(\.name))
      #expect(accountColumns.contains("group_id"))

      let foreignKeys = try Row.fetchAll(
        database, sql: "PRAGMA foreign_key_list(\"account\")")
      let groupForeignKey = foreignKeys.first { row in
        (row["from"] as String?) == "group_id"
      }
      #expect(groupForeignKey == nil, "account.group_id must not have a FK constraint")

      let indexNames = try Row.fetchAll(
        database,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type='index' AND tbl_name IN ('account_group', 'account')
          """
      ).compactMap { $0["name"] as String? }
      #expect(indexNames.contains("account_group_by_bucket_position"))
      #expect(indexNames.contains("account_by_group_id"))

      let createSQL: String? = try String.fetchOne(
        database,
        sql: """
          SELECT sql FROM sqlite_master
          WHERE type='table' AND name='account_group'
          """)
      let sqlText = try #require(createSQL)
      #expect(sqlText.uppercased().contains("STRICT"))
    }
  }
}
