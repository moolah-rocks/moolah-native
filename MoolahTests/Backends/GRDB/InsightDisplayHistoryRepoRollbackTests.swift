import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Insight display history GRDB rollback contracts")
struct InsightDisplayHistoryRepoRollbackTests {
  @Test("a failed retention purge rolls back newly recorded displays")
  func failedPurgeRollsBackUpserts() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repository = GRDBInsightDisplayHistoryRepository(database: database)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let staleDate = now.addingTimeInterval(-100 * 24 * 60 * 60)

    try await database.write { database in
      try InsightDisplayHistoryRow(
        presentationKey: "stale", lastShownAt: staleDate
      ).insert(database)
      try database.execute(
        sql: """
          CREATE TRIGGER fail_history_purge
          BEFORE DELETE ON insight_display_history
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    do {
      try await repository.recordShown(["new"], at: now)
      Issue.record("recordShown should have thrown but did not")
    } catch {
      // Expected — the purge trigger raises ABORT.
    }

    let rows = try await database.read { database in
      try InsightDisplayHistoryRow.fetchAll(database)
    }
    #expect(rows.map(\.presentationKey) == ["stale"])
    #expect(rows.first?.lastShownAt == staleDate)
  }
}
