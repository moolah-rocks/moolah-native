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
  private static let date = Date(timeIntervalSince1970: 1_700_000_000)

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

  // MARK: - Soft-delete lock

  @Test("account delete is a soft hide and journals nothing")
  func accountSoftDeleteDoesNotJournal() async throws {
    let database = try makeDatabase()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: try SharedRegistryTestSupport.makeSharedRegistry(),
      instrumentRegistrar: try SharedRegistryTestSupport.makeSharedRegistry())
    let account = Account(name: "Checking", type: .bank, instrument: .AUD)
    _ = try await repo.create(account)

    try await repo.delete(id: account.id)

    // `delete(id:)` flips `is_hidden` (an UPDATE) and must never journal a
    // deletion intent — a soft hide is not a propagated deletion.
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - Atomicity

  @Test("a forced failure journaling a delete rolls back the row delete too")
  func deleteAndJournalAreAtomic() async throws {
    let database = try makeDatabase()
    let repo = GRDBCategoryRepository(database: database)
    let id = UUID()
    _ = try await repo.create(Category(id: id, name: "Food"))

    // Abort any insert into the journal — the delete write must roll back whole.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_journal BEFORE INSERT ON deletion_journal
          BEGIN SELECT RAISE(ABORT, 'forced journal failure'); END;
          """)
    }
    await #expect(throws: (any Error).self) {
      try await repo.delete(id: id, withReplacement: nil)
    }

    // The row survived (the delete rolled back with the failed journal insert)
    // and no tombstone landed — the row delete and the journal write are one
    // transaction.
    let survived = try await database.read {
      try CategoryRow.fetchOne($0, key: id) != nil
    }
    #expect(survived)
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - D1-b recreate-clears sweep (other hard-delete types)

  @Test("account-group delete journals it; re-create clears the intent")
  func accountGroupDeleteThenRecreateClears() async throws {
    let database = try makeDatabase()
    let repo = GRDBAccountGroupRepository(database: database)
    let id = UUID()
    let group = AccountGroup(id: id, name: "Cash", bucket: .current, instrument: .AUD)
    _ = try await repo.create(group)
    try await repo.delete(id: id)
    #expect(try await entries(database).map(\.recordName) == [AccountGroupRow.recordName(for: id)])
    _ = try await repo.create(group)
    #expect(try await entries(database).isEmpty)
  }

  @Test("transfer-suggestion delete journals it; re-create clears the intent")
  func transferSuggestionDeleteThenRecreateClears() async throws {
    let database = try makeDatabase()
    let repo = GRDBTransferSuggestionRepository(database: database)
    let suggestion = TransferSuggestion(
      transactionIds: [UUID(), UUID()], suggestedAt: Self.date)
    _ = try await repo.create(suggestion)
    try await repo.delete(id: suggestion.id)
    #expect(
      try await entries(database).map(\.recordName)
        == [TransferSuggestionRow.recordName(for: suggestion.id)])
    _ = try await repo.create(suggestion)
    #expect(try await entries(database).isEmpty)
  }

  @Test("csv-import-profile delete journals it; re-create clears the intent")
  func csvImportProfileDeleteThenRecreateClears() async throws {
    let database = try makeDatabase()
    let repo = GRDBCSVImportProfileRepository(database: database)
    let id = UUID()
    let profile = CSVImportProfile(
      id: id, accountId: UUID(), parserIdentifier: "generic", headerSignature: ["Date", "Amount"])
    _ = try await repo.create(profile)
    try await repo.delete(id: id)
    #expect(
      try await entries(database).map(\.recordName) == [CSVImportProfileRow.recordName(for: id)])
    _ = try await repo.create(profile)
    #expect(try await entries(database).isEmpty)
  }

  @Test("import-rule delete journals it; re-create clears the intent")
  func importRuleDeleteThenRecreateClears() async throws {
    let database = try makeDatabase()
    let repo = GRDBImportRuleRepository(database: database)
    let id = UUID()
    let rule = ImportRule(id: id, name: "R", position: 0, conditions: [], actions: [])
    _ = try await repo.create(rule)
    try await repo.delete(id: id)
    #expect(try await entries(database).map(\.recordName) == [ImportRuleRow.recordName(for: id)])
    _ = try await repo.create(rule)
    #expect(try await entries(database).isEmpty)
  }

  @Test("investment removeValue journals the deleted value under the sentinel zone")
  func investmentRemoveValueJournals() async throws {
    let database = try makeDatabase()
    let repo = GRDBInvestmentRepository(
      database: database,
      defaultInstrument: .AUD,
      instrumentResolver: try SharedRegistryTestSupport.makeSharedRegistry())
    let accountId = UUID()
    let amount = InstrumentAmount(quantity: 100, instrument: .AUD)
    try await repo.setValue(accountId: accountId, date: Self.date, value: amount)
    #expect(try await entries(database).isEmpty)

    try await repo.removeValue(accountId: accountId, date: Self.date)
    let recorded = try await entries(database)
    #expect(recorded.count == 1)
    #expect(recorded.first?.zoneName == DeletionJournal.profileDataSentinelZone)
    #expect(recorded.first?.recordType == InvestmentValueRow.recordType)

    // `setValue` after a remove mints a NEW value id (a new record), so the
    // removed value's deletion correctly still stands — D1-b clears a tombstone
    // only when the SAME id is re-created, which the other suites cover.
    try await repo.setValue(accountId: accountId, date: Self.date, value: amount)
    #expect(try await entries(database).count == 1)
  }

  // MARK: - Local-teardown lock: `deleteAllSync` (server-driven local clear)
  //
  // `deleteAllSync` is the `deleteLocalData` mirror clear (iCloud account
  // change / remote zone deletion) — server-driven, NOT user intent. It fires
  // no record hooks and must journal NOTHING, else a sign-out / account-switch
  // would queue server `.deleteRecord`s for data the server already dropped
  // (the inverted-resurrection hazard). As load-bearing as the soft-delete
  // lock, asserted per wired type.

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
    let repo = GRDBInvestmentRepository(
      database: database,
      defaultInstrument: .AUD,
      instrumentResolver: try SharedRegistryTestSupport.makeSharedRegistry())
    try await repo.setValue(
      accountId: UUID(), date: Self.date, value: InstrumentAmount(quantity: 5, instrument: .AUD))
    try repo.deleteAllSync()
    #expect(try await entries(database).isEmpty)
  }

  @Test("investment removeAllValues is user-intent and journals every removed value")
  func investmentRemoveAllValuesJournals() async throws {
    let database = try makeDatabase()
    let repo = GRDBInvestmentRepository(
      database: database,
      defaultInstrument: .AUD,
      instrumentResolver: try SharedRegistryTestSupport.makeSharedRegistry())
    let accountId = UUID()
    let amount = InstrumentAmount(quantity: 5, instrument: .AUD)
    try await repo.setValue(accountId: accountId, date: Self.date, value: amount)
    try await repo.setValue(
      accountId: accountId, date: Self.date.addingTimeInterval(86_400), value: amount)

    let removed = try await repo.removeAllValues(accountId: accountId)
    #expect(removed == 2)
    let recorded = try await entries(database)
    // Unlike `deleteAllSync`, this is a user-intent bulk delete (fires per-row
    // hooks) and MUST journal each removed value.
    #expect(recorded.count == 2)
    #expect(recorded.allSatisfy { $0.zoneName == DeletionJournal.profileDataSentinelZone })
    #expect(recorded.allSatisfy { $0.recordType == InvestmentValueRow.recordType })
  }
}
