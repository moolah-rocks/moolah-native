import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema insight_display_history table")
struct ProfileSchemaInsightDisplayHistoryTests {
  @Test("migration creates a strict semantic-key history table")
  func migrationCreatesTable() throws {
    let database = try ProfileDatabase.openInMemory()

    try database.read { database in
      #expect(try database.tableExists("insight_display_history"))
      let columns = try database.columns(in: "insight_display_history")
      #expect(columns.map(\.name) == ["presentation_key", "last_shown_at"])
      #expect(
        try Int.fetchOne(
          database,
          sql: "SELECT pk FROM pragma_table_info(?) WHERE name = ?",
          arguments: ["insight_display_history", "presentation_key"]) == 1)
      #expect(
        try Int.fetchOne(
          database,
          sql: "SELECT strict FROM pragma_table_list WHERE name = ?",
          arguments: ["insight_display_history"]) == 1)
    }
  }
}
