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

  // MARK: - Transaction (+legs) — the #1093 reused-id interleave
  //
  // The data-loss gate: a leg edit goes through `replace` / `update` =
  // delete-then-recreate the SAME leg ids. The recreate-half MUST clear the
  // delete-half's tombstones (via the `performCreateMany` / `performUpdate`
  // chokepoints), netting ZERO journal rows for surviving legs — otherwise
  // PR-B replay would later delete a live leg (silent #1085-class loss).

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
      date: Self.date,
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50, type: .expense),
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 50, type: .income),
      ])
    _ = try await repo.create(txn)
    #expect(try await entries(database).isEmpty)

    try await repo.delete(id: txn.id)
    let recorded = try await entries(database)
    #expect(recorded.count == 3)
    #expect(recorded.allSatisfy { $0.zoneName == DeletionJournal.profileDataSentinelZone })
    let names = Set(recorded.map(\.recordName))
    #expect(names.contains(TransactionRow.recordName(for: txn.id)))
    for leg in txn.legs {
      #expect(names.contains(TransactionLegRow.recordName(for: leg.id)))
    }
  }

  @Test("replace reusing the header + a leg journals ONLY the genuinely-removed leg")
  func transactionReplaceReuseJournalsOnlyRemovedLeg() async throws {
    let database = try makeDatabase()
    let repo = try makeTransactionRepo(database)
    let accountId = UUID()
    let legA = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50, type: .expense)
    let legB = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 50, type: .income)
    let txn = Transaction(date: Self.date, legs: [legA, legB])
    _ = try await repo.create(txn)

    // Reuse the header id + legA (rewritten), drop legB, add legC.
    let legC = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 10, type: .income)
    let rebuilt = Transaction(id: txn.id, date: txn.date, legs: [legA, legC])
    _ = try await repo.replace(deletingIds: [txn.id], creating: [rebuilt])

    // Only legB is journaled; the reused header, reused legA, and new legC are
    // cleared by `performCreateMany` — no live-leg tombstone.
    #expect(
      try await entries(database).map(\.recordName) == [TransactionLegRow.recordName(for: legB.id)])
  }

  @Test("update (leg-diff / automation path) journals ONLY removed legs, not survivors")
  func transactionUpdateJournalsOnlyRemovedLegs() async throws {
    let database = try makeDatabase()
    let repo = try makeTransactionRepo(database)
    let accountId = UUID()
    let legA = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50, type: .expense)
    let legB = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 50, type: .income)
    let txn = Transaction(date: Self.date, legs: [legA, legB])
    _ = try await repo.create(txn)

    // Edit via `update` (the path automation's updateLeg/addLeg/removeLeg take
    // after #1093): keep legA (same id, rewritten quantity), drop legB, add legC.
    let editedA = TransactionLeg(
      id: legA.id, accountId: accountId, instrument: .AUD, quantity: -75, type: .expense)
    let legC = TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 25, type: .income)
    _ = try await repo.update(Transaction(id: txn.id, date: txn.date, legs: [editedA, legC]))

    // Only legB (removed) is journaled; surviving legA, new legC, and the
    // header are cleared by `performUpdate` — no live-leg tombstone.
    #expect(
      try await entries(database).map(\.recordName) == [TransactionLegRow.recordName(for: legB.id)])
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
}
