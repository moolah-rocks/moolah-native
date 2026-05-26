import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v15_account_group_ui_state migration")
struct AccountGroupUIStateMigrationTests {
  @Test("creates account_group_ui table with expected columns")
  func createsTableWithExpectedColumns() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      let columns = try database.columns(in: "account_group_ui")
      let names = columns.map(\.name)
      #expect(names == ["group_id", "is_expanded"])
    }
  }

  @Test("group_id is the primary key")
  func groupIdIsPrimaryKey() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      let columns = try database.columns(in: "account_group_ui")
      let primary = columns.first { $0.primaryKeyIndex > 0 }
      #expect(primary?.name == "group_id")
    }
  }

  @Test("FK to account_group with ON DELETE CASCADE")
  func foreignKeyCascadesOnDelete() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    try queue.read { database in
      let rows = try Row.fetchAll(
        database, sql: "PRAGMA foreign_key_list(account_group_ui)")
      #expect(rows.count == 1)
      let foreignKey = try #require(rows.first)
      #expect(foreignKey["table"] as? String == "account_group")
      #expect(foreignKey["from"] as? String == "group_id")
      #expect(foreignKey["to"] as? String == "id")
      #expect(foreignKey["on_delete"] as? String == "CASCADE")
    }
  }

  @Test("deleting parent group cascades to account_group_ui row")
  func cascadeDeletesUIStateWhenGroupDeleted() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    let groupId = UUID()
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account_group
            (id, record_name, name, bucket, instrument_id, position)
          VALUES (?, ?, 'G', 'investments', 'AUD', 0)
          """,
        arguments: [groupId, "AccountGroupRecord|\(groupId.uuidString)"])
      try database.execute(
        sql: "INSERT INTO account_group_ui (group_id, is_expanded) VALUES (?, 1)",
        arguments: [groupId])
    }

    try queue.write { database in
      try database.execute(
        sql: "DELETE FROM account_group WHERE id = ?", arguments: [groupId])
    }

    let remaining = try queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM account_group_ui WHERE group_id = ?",
        arguments: [groupId]) ?? 0
    }
    #expect(remaining == 0)
  }

  @Test("INSERT omitting is_expanded receives DEFAULT 0")
  func defaultIsExpandedIsZero() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)

    let groupId = UUID()
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO account_group
            (id, record_name, name, bucket, instrument_id, position)
          VALUES (?, ?, 'G', 'investments', 'AUD', 0)
          """,
        arguments: [groupId, "AccountGroupRecord|\(groupId.uuidString)"])
      try database.execute(
        sql: "INSERT INTO account_group_ui (group_id) VALUES (?)",
        arguments: [groupId])
    }

    let expanded = try queue.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT is_expanded FROM account_group_ui WHERE group_id = ?",
        arguments: [groupId])
    }
    #expect(expanded == 0)
  }
}
