import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the contract that every GRDB repository's `onRecordChanged` /
/// `onRecordDeleted` hook fires with the right `recordType` for every
/// row it mutates. Repositories that mutate more than one record type
/// (legs, budget items, child categories, the txn+leg pair built from
/// an opening balance) must tag each emit with its own type — the
/// `nextRecordZoneChangeBatch` lookup keys off these strings, so a
/// regression silently converts uploads into phantom deletes.
@Suite("Repository hooks emit (recordType, id) pairs")
@MainActor
struct RepositoryHookRecordTypeTests {

  // MARK: - Capture Helper

  /// Confined to `@MainActor` so the (non-Sendable) closures wired to the
  /// repository can append into the buffers without crossing actors.
  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
  }

  // MARK: - Hook bridges

  /// Wraps a `HookCapture` in `@Sendable` closures by hopping back to the
  /// main actor before mutating the (non-Sendable) capture.
  private func makeChangedHook(
    _ capture: HookCapture
  ) -> @Sendable (String, UUID) -> Void {
    { recordType, id in
      Task { @MainActor in
        capture.changed.append((recordType, id))
      }
    }
  }

  private func makeDeletedHook(
    _ capture: HookCapture
  ) -> @Sendable (String, UUID) -> Void {
    { recordType, id in
      Task { @MainActor in
        capture.deleted.append((recordType, id))
      }
    }
  }

  /// Drains queued main-actor hops so callers can read the capture state
  /// after a repository write completes. The hooks dispatch onto
  /// `@MainActor` to avoid Sendable smuggling, so the capture buffers
  /// aren't populated synchronously with the write returning.
  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  // MARK: - TransactionRepository

  @Test("create(_:) emits one TransactionRecord and one TransactionLegRecord per leg")
  func transactionCreateEmitsLegRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    // Leg-level hooks are emitted via the txn repo's bundled write path;
    // the legs hook closures we install here are observers only — they're
    // exercised by the leg-rows the txn repo writes alongside the header.
    let legHooksRepo = GRDBTransactionLegRepository(
      database: database,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    _ = legHooksRepo  // silence unused — installed for hook coverage

    let accountId = UUID()
    let txn = Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
      ]
    )

    _ = try await txnRepo.create(txn)
    try await drainHookHops()

    let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnEmits.map(\.id) == [txn.id])
    let legEmits = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    // One leg-record emit per leg the txn write inserted (two legs in
    // this transfer). A regression that drops the per-leg emit would
    // surface as `legEmits.count == 0`.
    #expect(legEmits.count == 2)
    #expect(capture.deleted.isEmpty)
  }

  // MARK: - AccountRepository

  @Test("create with opening balance tags account, txn, and leg with their own record types")
  func accountCreateOpeningBalanceTagsRecordTypes() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let account = Account(name: "Cash", type: .bank, instrument: .defaultTestInstrument)
    _ = try await repo.create(
      account,
      openingBalance: InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))
    try await drainHookHops()

    let accountEmits = capture.changed.filter { $0.recordType == AccountRow.recordType }
    #expect(accountEmits.map(\.id) == [account.id])
    // Opening-balance create writes a one-leg synthetic transaction
    // alongside the account row; one txn-record + one leg-record emit
    // each. A regression that mis-tags the txn or leg emit with the
    // account record type would drop these to zero.
    let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    let legEmits = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    #expect(txnEmits.count == 1)
    #expect(legEmits.count == 1)
  }

  // MARK: - EarmarkRepository

  @Test("setBudget emits with EarmarkBudgetItemRecord, not EarmarkRecord")
  func earmarkSetBudgetTagsBudgetItemRecord() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      instrumentResolver: (try SharedRegistryTestSupport.makeSharedRegistry()),
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    let earmark = try await earmarkRepo.create(
      Earmark(name: "Holiday", instrument: .defaultTestInstrument))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    try await earmarkRepo.setBudget(
      earmarkId: earmark.id,
      categoryId: UUID(),
      amount: InstrumentAmount(quantity: 50, instrument: .defaultTestInstrument))
    try await drainHookHops()

    let earmarkEmits = capture.changed.filter { $0.recordType == EarmarkRow.recordType }
    #expect(earmarkEmits.isEmpty)
    // The setBudget write emits exactly one budget-item record so the
    // sync engine queues an EarmarkBudgetItemRecord upload (not an
    // EarmarkRecord one). A regression that mis-tags the emit would
    // surface as a zero count here.
    let budgetEmits = capture.changed.filter {
      $0.recordType == EarmarkBudgetItemRow.recordType
    }
    #expect(budgetEmits.count == 1)
  }

  // MARK: - CategoryRepository

  /// Pins the multi-type fan-out from `delete(id:withReplacement:)`.
  /// The cascade emits four record types in one call: the deleted
  /// category itself, any orphaned children (CategoryRecord), any legs
  /// whose category was reassigned to the replacement
  /// (TransactionLegRecord), and any budget items that were either
  /// rerouted or deleted (EarmarkBudgetItemRecord). A regression that
  /// mis-tags any one of these emits would silently corrupt sync —
  /// `nextRecordZoneChangeBatch` keys off the recordType string.
  @Test(
    "delete cascade tags Category, TransactionLeg, and EarmarkBudgetItem with their own record types"
  )
  func categoryDeleteEmitsCascadingRecordTypes() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let categoryRepo = GRDBCategoryRepository(
      database: database,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let ids = CategoryDeleteFixtureIds()
    try await seedCategoryDeleteFixture(in: database, ids: ids)

    try await categoryRepo.delete(id: ids.parentId, withReplacement: ids.replacementId)
    try await drainHookHops()
    let parentId = ids.parentId
    let childId = ids.childId
    let legId = ids.legId
    let budgetItemId = ids.budgetItemId

    // 1. The deleted category itself — exactly one CategoryRecord delete
    //    keyed by parentId.
    let categoryDeletes = capture.deleted.filter { $0.recordType == CategoryRow.recordType }
    #expect(categoryDeletes.map(\.id) == [parentId])

    // 2. Orphaned child — emitted as CategoryRecord *change* (parent_id
    //    nulled), not delete.
    let categoryChanges = capture.changed.filter { $0.recordType == CategoryRow.recordType }
    #expect(categoryChanges.map(\.id) == [childId])

    // 3. Reassigned leg — emitted as TransactionLegRecord change.
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    #expect(legChanges.map(\.id) == [legId])

    // 4. Budget item whose category was rerouted to the replacement —
    //    emitted as EarmarkBudgetItemRecord change (no duplicate exists,
    //    so the row is updated rather than deleted).
    let budgetChanges = capture.changed.filter {
      $0.recordType == EarmarkBudgetItemRow.recordType
    }
    #expect(budgetChanges.map(\.id) == [budgetItemId])

    // No EarmarkRecord emits — earmark itself wasn't touched.
    let earmarkEmits = capture.changed.filter { $0.recordType == EarmarkRow.recordType }
    #expect(earmarkEmits.isEmpty)
  }

  // MARK: - Category-delete fixture

  /// IDs threaded through `seedCategoryDeleteFixture` so the test can
  /// assert against them by name rather than by re-fetching.
  private struct CategoryDeleteFixtureIds {
    let parentId = UUID()
    let childId = UUID()
    let replacementId = UUID()
    let accountId = UUID()
    let earmarkId = UUID()
    let legId = UUID()
    let budgetItemId = UUID()
    let txnId = UUID()
  }

  /// Seeds a fixture covering every record type the category-delete
  /// cascade fans out to. Writes are split across small per-topic
  /// transactions; correctness only requires that all rows are present
  /// before the test drives `delete`, not that they share a write.
  private func seedCategoryDeleteFixture(
    in database: any DatabaseWriter, ids: CategoryDeleteFixtureIds
  ) async throws {
    try await seedCategories(in: database, ids: ids)
    try await seedAccountAndEarmark(in: database, ids: ids)
    try await seedBudgetAndTransaction(in: database, ids: ids)
  }

  private func seedCategories(
    in database: any DatabaseWriter, ids: CategoryDeleteFixtureIds
  ) async throws {
    try await database.write { database in
      try CategoryRow(domain: Moolah.Category(id: ids.parentId, name: "Parent"))
        .insert(database)
      try CategoryRow(
        domain: Moolah.Category(id: ids.childId, name: "Child", parentId: ids.parentId)
      ).insert(database)
      try CategoryRow(domain: Moolah.Category(id: ids.replacementId, name: "Replacement"))
        .insert(database)
    }
  }

  private func seedAccountAndEarmark(
    in database: any DatabaseWriter, ids: CategoryDeleteFixtureIds
  ) async throws {
    try await database.write { database in
      try AccountRow(
        domain: Account(id: ids.accountId, name: "Cash", type: .bank, instrument: .AUD)
      ).insert(database)
      try EarmarkRow(
        domain: Earmark(id: ids.earmarkId, name: "Holiday", instrument: .AUD)
      ).insert(database)
    }
  }

  private func seedBudgetAndTransaction(
    in database: any DatabaseWriter, ids: CategoryDeleteFixtureIds
  ) async throws {
    try await seedBudgetItem(in: database, ids: ids)
    try await seedTransactionAndLeg(in: database, ids: ids)
  }

  private func seedBudgetItem(
    in database: any DatabaseWriter, ids: CategoryDeleteFixtureIds
  ) async throws {
    try await database.write { database in
      try EarmarkBudgetItemRow(
        id: ids.budgetItemId,
        recordName: EarmarkBudgetItemRow.recordName(for: ids.budgetItemId),
        earmarkId: ids.earmarkId,
        categoryId: ids.parentId,
        amount: 1_000,
        instrumentId: Instrument.AUD.id,
        encodedSystemFields: nil
      ).insert(database)
    }
  }

  private func seedTransactionAndLeg(
    in database: any DatabaseWriter, ids: CategoryDeleteFixtureIds
  ) async throws {
    let txn = TransactionRow(
      id: ids.txnId,
      recordName: TransactionRow.recordName(for: ids.txnId),
      date: Date(), payee: "Train", notes: nil,
      recurPeriod: nil, recurEvery: nil,
      importOriginRawDescription: nil, importOriginBankReference: nil,
      importOriginRawAmount: nil, importOriginRawBalance: nil,
      importOriginImportedAt: nil, importOriginImportSessionId: nil,
      importOriginSourceFilename: nil, importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    let leg = TransactionLegRow(
      id: ids.legId,
      recordName: TransactionLegRow.recordName(for: ids.legId),
      transactionId: ids.txnId,
      accountId: ids.accountId,
      instrumentId: Instrument.AUD.id,
      quantity: -100,
      type: TransactionType.expense.rawValue,
      categoryId: ids.parentId,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    try await database.write { database in
      try txn.insert(database)
      try leg.insert(database)
    }
  }
}
