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

  // MARK: - Transaction (+legs)

  private func makeTransactionRepo(_ database: DatabaseQueue) throws -> GRDBTransactionRepository {
    GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FixedConversionService(),
      instrumentResolver: try SharedRegistryTestSupport.makeSharedRegistry(),
      instrumentRegistrar: try SharedRegistryTestSupport.makeSharedRegistry())
  }

  @Test("transaction delete journals the header and every leg under the sentinel zone")
  func transactionDeleteJournalsHeaderAndLegs() async throws {
    let database = try makeDatabase()
    let repo = try makeTransactionRepo(database)
    let accountId = UUID()
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50, type: .expense),
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 50, type: .income),
      ])
    _ = try await repo.create(txn)
    #expect(try await entries(database).isEmpty)

    try await repo.delete(id: txn.id)
    let recorded = try await entries(database)
    // Header + 2 legs = 3 intents, every one stored under the sentinel zone.
    #expect(recorded.count == 3)
    #expect(recorded.allSatisfy { $0.zoneName == DeletionJournal.profileDataSentinelZone })
    let names = Set(recorded.map(\.recordName))
    #expect(names.contains(TransactionRow.recordName(for: txn.id)))
    for leg in txn.legs {
      #expect(names.contains(TransactionLegRow.recordName(for: leg.id)))
    }
  }

  @Test("replace reusing the header + a leg journals only the removed leg")
  func transactionReplaceReuseJournalsOnlyRemovedLeg() async throws {
    let database = try makeDatabase()
    let repo = try makeTransactionRepo(database)
    let accountId = UUID()
    let legA = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50, type: .expense)
    let legB = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 50, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), legs: [legA, legB])
    _ = try await repo.create(txn)

    // Rewrite under the SAME header id, reusing legA, dropping legB, adding legC.
    let legC = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 10, type: .income)
    let rebuilt = Transaction(id: txn.id, date: txn.date, legs: [legA, legC])
    _ = try await repo.replace(deletingIds: [txn.id], creating: [rebuilt])

    let recorded = try await entries(database)
    // Only legB (deleted and NOT re-created) is journaled; the reused header,
    // reused legA, and new legC are not.
    #expect(recorded.map(\.recordName) == [TransactionLegRow.recordName(for: legB.id)])
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
}
