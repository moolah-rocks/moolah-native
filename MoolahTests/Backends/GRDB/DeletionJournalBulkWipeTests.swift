import Foundation
import GRDB
import Testing

@testable import Moolah

/// Locks the bulk-delete distinction for the deletion journal (issue #1090):
/// `deleteAllSync` is the server-driven `deleteLocalData` mirror clear (iCloud
/// account change / remote zone deletion) — NOT user intent — and must journal
/// NOTHING (else a sign-out / account-switch would queue server `.deleteRecord`s
/// for data the server already dropped: the inverted-resurrection hazard). The
/// lone user-intent bulk delete, `InvestmentValue.removeAllValues`, fires
/// per-row hooks and DOES journal each value. As load-bearing as the
/// soft-delete-account lock.
@Suite("DeletionJournal — bulk-wipe distinction")
struct DeletionJournalBulkWipeTests {
  private static let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileDatabase.openInMemory()
  }

  private func entries(_ database: DatabaseQueue) async throws -> [DeletionJournalRow] {
    try await database.read { try DeletionJournal.allEntries(in: $0) }
  }

  private func makeInvestmentRepo(_ database: DatabaseQueue) throws -> GRDBInvestmentRepository {
    GRDBInvestmentRepository(
      database: database,
      defaultInstrument: .AUD,
      instrumentResolver: try SharedRegistryTestSupport.makeSharedRegistry())
  }

  // MARK: - deleteAllSync journals nothing (per wired type)

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

  @Test("investment deleteAllSync journals nothing")
  func investmentDeleteAllSyncDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = try makeInvestmentRepo(database)
    try await repo.setValue(
      accountId: UUID(), date: Self.date, value: InstrumentAmount(quantity: 5, instrument: .AUD))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - user-intent bulk delete DOES journal

  @Test("investment removeAllValues is user-intent and journals every removed value")
  func investmentRemoveAllValuesJournals() async throws {
    let database = try makeDatabase()
    let repo = try makeInvestmentRepo(database)
    let accountId = UUID()
    let amount = InstrumentAmount(quantity: 5, instrument: .AUD)
    try await repo.setValue(accountId: accountId, date: Self.date, value: amount)
    try await repo.setValue(
      accountId: accountId, date: Self.date.addingTimeInterval(86_400), value: amount)

    let removed = try await repo.removeAllValues(accountId: accountId)
    #expect(removed == 2)
    let recorded = try await entries(database)
    #expect(recorded.count == 2)
    #expect(recorded.allSatisfy { $0.zoneName == DeletionJournal.profileDataSentinelZone })
    #expect(recorded.allSatisfy { $0.recordType == InvestmentValueRow.recordType })
  }
}
