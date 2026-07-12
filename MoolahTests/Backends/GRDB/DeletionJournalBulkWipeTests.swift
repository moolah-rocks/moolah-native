import Foundation
import GRDB
import Testing

@testable import Moolah

/// Locks the bulk-delete distinction for the deletion journal (issue #1090):
/// `deleteAllSync` is the server-driven `deleteLocalData` mirror clear and
/// must journal nothing.
@Suite("DeletionJournal — bulk-wipe distinction")
struct DeletionJournalBulkWipeTests {
  private static let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileDatabase.openInMemory()
  }

  private func entries(_ database: DatabaseQueue) async throws -> [DeletionJournalRow] {
    try await database.read { try DeletionJournal.allEntries(in: $0) }
  }

  @Test("category deleteAllSync journals nothing")
  func categoryDeleteAllSyncDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = GRDBCategoryRepository(database: database)
    _ = try await repo.create(Category(name: "A"))
    _ = try await repo.create(Category(name: "B"))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }

  @Test("account-group deleteAllSync journals nothing")
  func accountGroupDeleteAllSyncDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = GRDBAccountGroupRepository(database: database)
    _ = try await repo.create(AccountGroup(name: "G", bucket: .current, instrument: .AUD))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }

  @Test("transfer-suggestion deleteAllSync journals nothing")
  func transferSuggestionDeleteAllSyncDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = GRDBTransferSuggestionRepository(database: database)
    _ = try await repo.create(
      TransferSuggestion(transactionIds: [UUID(), UUID()], suggestedAt: Self.date))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }

  @Test("import-rule deleteAllSync journals nothing")
  func importRuleDeleteAllSyncDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = GRDBImportRuleRepository(database: database)
    _ = try await repo.create(ImportRule(name: "R", position: 0, conditions: [], actions: []))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }

  @Test("csv-import-profile deleteAllSync journals nothing")
  func csvImportProfileDeleteAllSyncDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = GRDBCSVImportProfileRepository(database: database)
    _ = try await repo.create(
      CSVImportProfile(accountId: UUID(), parserIdentifier: "generic", headerSignature: ["D"]))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }
}
