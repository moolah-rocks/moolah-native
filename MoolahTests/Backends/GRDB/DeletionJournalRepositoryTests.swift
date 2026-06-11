import Foundation
import GRDB
import Testing

@testable import Moolah

/// Integration tests for the per-profile data repositories' deletion-journal
/// wiring (issue #1090, Option B sentinel zone): a hard delete records a
/// durable intent in the same transaction, a (re-)create or peer save clears
/// it (D1-b), and a server-originated apply-path delete never journals.
@Suite("DeletionJournal — per-profile data repos")
struct DeletionJournalRepositoryTests {
  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileDatabase.openInMemory()
  }

  private func entries(_ database: DatabaseQueue) async throws -> [DeletionJournalRow] {
    try await database.read { try DeletionJournal.allEntries(in: $0) }
  }

  // MARK: - Category

  @Test("category delete journals it under the sentinel zone; re-create clears it")
  func categoryDeleteJournalsThenRecreateClears() async throws {
    let database = try makeDatabase()
    let repo = GRDBCategoryRepository(database: database)
    let id = UUID()

    _ = try await repo.create(Category(id: id, name: "Food"))
    #expect(try await entries(database).isEmpty)

    try await repo.delete(id: id, withReplacement: nil)
    let afterDelete = try await entries(database)
    #expect(afterDelete.count == 1)
    let entry = try #require(afterDelete.first)
    #expect(entry.zoneName == DeletionJournal.profileDataSentinelZone)
    #expect(entry.recordName == CategoryRow.recordName(for: id))
    #expect(entry.recordType == CategoryRow.recordType)

    // D1-b: re-creating the same id drops the stale intent.
    _ = try await repo.create(Category(id: id, name: "Food"))
    #expect(try await entries(database).isEmpty)
  }

  @Test("category apply-path: save clears a stale intent, server delete does not journal")
  func categoryApplyPathClearsOnSaveAndNeverJournalsDeletes() async throws {
    let database = try makeDatabase()
    let repo = GRDBCategoryRepository(database: database)
    let id = UUID()

    _ = try await repo.create(Category(id: id, name: "X"))
    try await repo.delete(id: id, withReplacement: nil)
    #expect(try await entries(database).count == 1)

    // A peer's save of the same id clears our stale intent (D1-b).
    let row = CategoryRow(domain: Category(id: id, name: "X"))
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try await entries(database).isEmpty)

    // A server-originated delete is already propagated — never journaled.
    try repo.applyRemoteChangesSync(saved: [], deleted: [id])
    #expect(try await entries(database).isEmpty)
  }
}
