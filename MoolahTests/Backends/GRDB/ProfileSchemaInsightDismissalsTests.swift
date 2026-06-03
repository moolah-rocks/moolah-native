import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema insight_dismissal table")
struct ProfileSchemaInsightDismissalsTests {
  @Test
  func tableExistsWithExpectedColumns() throws {
    let queue = try ProfileDatabase.openInMemory()
    try queue.read { database in
      #expect(try database.tableExists("insight_dismissal"))
      let columns = try database.columns(in: "insight_dismissal").map(\.name)
      #expect(columns.contains("id"))
      #expect(columns.contains("record_name"))
      #expect(columns.contains("kind"))
      #expect(columns.contains("count"))
      #expect(columns.contains("encoded_system_fields"))
    }
  }

  @Test
  func kindIsUnique() throws {
    let queue = try ProfileDatabase.openInMemory()
    let row = InsightDismissalRow(kind: .newRecurringDetected, count: 1)
    var dup = InsightDismissalRow(kind: .newRecurringDetected, count: 1)
    dup.id = UUID()  // distinct id, same kind → UNIQUE(kind) must reject
    dup.recordName = "InsightDismissalRecord|\(dup.id.uuidString)"
    try queue.write { database in try row.insert(database) }
    #expect(throws: (any Error).self) {
      try queue.write { database in try dup.insert(database) }
    }
  }
}
