// MoolahTests/Backends/GRDB/CoreFinancialGraphRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract tests for the multi-statement writes in the core
/// financial graph repositories. Each test seeds prior state, forces a
/// failure mid-transaction (typically by installing a BEFORE-INSERT or
/// BEFORE-UPDATE trigger), drives the production repository method, and
/// asserts the prior state survives byte-equal. A regression that moves
/// the `committed = true` line above the `database.write` block, or
/// splits a single transaction into two, would silently leave a torn
/// half-write on disk; these tests catch that.
@Suite("Core financial graph GRDB rollback contracts")
@MainActor
struct CoreFinancialGraphRollbackTests {

  // MARK: - GRDBAccountRepository.create(_:openingBalance:)

  @Test
  func accountCreateWithOpeningBalanceRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    // Pre-seed an account whose row must remain untouched after the
    // failed second-account create — its existence pins the "no torn
    // state" invariant when the failing create's transaction rolls back.
    let priorId = UUID()
    let prior = Account(id: priorId, name: "prior", type: .bank, instrument: .AUD)
    _ = try await repo.create(prior, openingBalance: nil)

    // Trigger that aborts the next leg insert with a sentinel record name.
    // The `create(...:openingBalance:)` write block inserts the account row,
    // a transaction header, and a leg in one `database.write` — the trigger
    // fires on the leg insert and the account+transaction inserts must roll
    // back too.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_create_leg
          BEFORE INSERT ON transaction_leg
          WHEN NEW.record_name LIKE '%___FAIL___%'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Construct a leg whose record_name will trip the trigger. The trigger
    // checks the record_name field; the production code derives it from the
    // leg id, so we can't easily pin it. Instead, force the failure via a
    // CHECK on `quantity` we can control: ABS(quantity) > 1e18 is impossible
    // for legitimate amounts but easy to trigger from a test.
    try await database.write { database in
      try database.execute(sql: "DROP TRIGGER fail_account_create_leg")
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_create_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let failingId = UUID()
    let failing = Account(id: failingId, name: "fail", type: .bank, instrument: .AUD)
    let openingBalance = InstrumentAmount(quantity: 100, instrument: .AUD)
    do {
      _ = try await repo.create(failing, openingBalance: openingBalance)
      Issue.record("create should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT.
    }

    // The failing account row must NOT be on disk; the prior account's
    // row must survive byte-equal.
    let accounts = try await database.read { database in
      try AccountRow.fetchAll(database)
    }
    let surviving = try #require(accounts.first { $0.id == priorId })
    #expect(surviving.name == "prior")
    #expect(!accounts.contains(where: { $0.id == failingId }))
  }

  // MARK: - GRDBTransactionRepository.create(_:)

  @Test
  func transactionCreateRollsBackOnLegFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let accountId = UUID()
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    // Install a trigger that aborts every leg insert; the create write
    // path inserts the txn header, then the legs — the trigger fires on
    // the first leg, and the txn header must roll back along with it.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_txn_create_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let txn = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -10, type: .expense)
      ])
    do {
      _ = try await txnRepo.create(txn)
      Issue.record("create should have thrown but did not")
    } catch {
      // Expected.
    }

    let txnRows = try await database.read { database in
      try TransactionRow.fetchAll(database)
    }
    let legRows = try await database.read { database in
      try TransactionLegRow.fetchAll(database)
    }
    #expect(txnRows.isEmpty)
    #expect(legRows.isEmpty)
  }

  // MARK: - GRDBTransactionRepository.update(_:)

  @Test
  func transactionUpdateRollsBackOnLegFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let accountId = UUID()
    try await seedAccountStub(in: database, accountId: accountId)

    // Seed a transaction with a single leg.
    let originalLeg = TransactionLeg(
      accountId: accountId, instrument: .AUD, quantity: -10, type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [originalLeg])
    _ = try await txnRepo.create(txn)
    let priorLegs = try await fetchLegs(in: database, transactionId: txn.id)
    #expect(priorLegs.count == 1)

    // Install a trigger that aborts any INSERT attempt on transaction_leg.
    // `performUpdate` now diffs legs by id: it deletes only legs absent
    // from the new array, then upserts each surviving/new leg via
    // `INSERT ... ON CONFLICT DO UPDATE`. SQLite fires `BEFORE INSERT`
    // for the upsert path, so the trigger raises ABORT on the first
    // upsert attempt; GRDB propagates the error and rolls the entire
    // write transaction back — undoing both the partial leg delete and
    // the header UPDATE.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_txn_update_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let mutated = Transaction(
      id: txn.id, date: txn.date, payee: "Tea", notes: nil,
      recurPeriod: nil, recurEvery: nil,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -42, type: .expense)
      ],
      importOrigin: nil)
    do {
      _ = try await txnRepo.update(mutated)
      Issue.record("update should have thrown but did not")
    } catch {
      // Expected.
    }

    // Header still has the original payee; leg rows match the pre-update
    // snapshot byte-equal.
    let header = try #require(
      try await database.read { database in
        try TransactionRow
          .filter(TransactionRow.Columns.id == txn.id)
          .fetchOne(database)
      })
    #expect(header.payee == "Coffee")
    let legsAfter = try await fetchLegs(in: database, transactionId: txn.id)
    #expect(legsAfter.map(\.id) == priorLegs.map(\.id))
    #expect(legsAfter.map(\.quantity) == priorLegs.map(\.quantity))
  }

  // MARK: - Transaction-update test helpers

  private func seedAccountStub(in database: any DatabaseWriter, accountId: UUID) async throws {
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }
  }

  private func fetchLegs(
    in database: any DatabaseWriter, transactionId: UUID
  ) async throws -> [TransactionLegRow] {
    try await database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == transactionId)
        .fetchAll(database)
    }
  }

  // MARK: - GRDBAccountRepository.update(_:)

  /// `update(_:)` does a fetch-then-update inside one `write` block;
  /// after the fix, the post-update position read also runs inside the
  /// same write transaction. A failure mid-update must leave the row
  /// byte-equal to its pre-call state. The fixture forces the failure
  /// via a BEFORE-UPDATE trigger so the row's first-pass UPDATE aborts
  /// after the row was loaded for mutation.
  @Test
  func accountUpdateRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let id = UUID()
    let original = Account(id: id, name: "Original", type: .bank, instrument: .AUD)
    _ = try await repo.create(original, openingBalance: nil)

    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_update
          BEFORE UPDATE ON account
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let mutated = Account(
      id: id, name: "Renamed", type: .bank, instrument: .AUD,
      position: 99, isHidden: true)
    do {
      _ = try await repo.update(mutated)
      Issue.record("update should have thrown but did not")
    } catch {
      // Expected.
    }

    // Original row survived byte-equal to the pre-update snapshot.
    let surviving = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == id).fetchOne(database)
    }
    let row = try #require(surviving)
    #expect(row.name == "Original")
    #expect(row.position != 99)
    #expect(row.isHidden == false)
  }

  // MARK: - GRDBEarmarkRepository.setBudget(...)

  @Test
  func earmarkSetBudgetRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database, defaultInstrument: .AUD,
      instrumentResolver: (try SharedRegistryTestSupport.makeSharedRegistry()))
    let categoryRepo = GRDBCategoryRepository(database: database)

    let earmarkId = UUID()
    let categoryId = UUID()
    let earmark = Earmark(id: earmarkId, name: "Trip", instrument: .AUD)
    let category = Moolah.Category(id: categoryId, name: "Travel")
    _ = try await earmarkRepo.create(earmark)
    _ = try await categoryRepo.create(category)

    // Install a trigger that aborts every earmark_budget_item insert.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_set_budget_insert
          BEFORE INSERT ON earmark_budget_item
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let amount = InstrumentAmount(quantity: 50, instrument: .AUD)
    do {
      try await earmarkRepo.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: amount)
      Issue.record("setBudget should have thrown but did not")
    } catch {
      // Expected.
    }

    let items = try await database.read { database in
      try EarmarkBudgetItemRow.fetchAll(database)
    }
    #expect(items.isEmpty)
  }
}
