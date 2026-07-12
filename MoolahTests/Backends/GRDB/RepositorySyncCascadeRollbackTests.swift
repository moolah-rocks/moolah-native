// MoolahTests/Backends/GRDB/RepositorySyncCascadeRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Paired rollback tests for the multi-statement sync delete cascades
/// added in the v5 FK-removal change. Per `DATABASE_CODE_GUIDE.md` §5,
/// every multi-statement write must be paired with a test that asserts
/// a thrown error inside the closure leaves the database unchanged.
///
/// Each test installs a `BEFORE DELETE` trigger on the final parent
/// table so the surrounding `database.write { … }` aborts after the
/// preceding child cascade statements have run. The `RAISE(ABORT)`
/// rolls the whole transaction back, and we assert all child rows
/// survive intact.
@Suite("Sync delete cascades roll back atomically on failure")
struct RepositorySyncCascadeRollbackTests {
  @Test
  func accountSyncDeleteRollsBackLegEdits() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let accountRepo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let fixture = try await Self.seedAccountScenario(in: database)

    do {
      try accountRepo.applyRemoteChangesSync(saved: [], deleted: [fixture.accountId])
      Issue.record("Expected applyRemoteChangesSync to throw")
    } catch {
      // Expected.
    }

    try await Self.assertAccountScenarioUnchanged(database: database, fixture: fixture)
  }

  @Test
  func earmarkSyncDeleteRollsBackBudgetItemAndLegEdits() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database, defaultInstrument: .AUD,
      instrumentResolver: (try SharedRegistryTestSupport.makeSharedRegistry()))
    let fixture = try await Self.seedEarmarkScenario(in: database)

    do {
      try earmarkRepo.applyRemoteChangesSync(saved: [], deleted: [fixture.earmarkId])
      Issue.record("Expected applyRemoteChangesSync to throw")
    } catch {
      // Expected.
    }

    try await Self.assertEarmarkScenarioUnchanged(database: database, fixture: fixture)
  }

  @Test
  func categorySyncDeleteRollsBackLegBudgetAndChildEdits() async throws {
    let database = try ProfileDatabase.openInMemory()
    let categoryRepo = GRDBCategoryRepository(database: database)
    let fixture = try await Self.seedCategoryScenario(in: database)

    do {
      try categoryRepo.applyRemoteChangesSync(saved: [], deleted: [fixture.categoryId])
      Issue.record("Expected applyRemoteChangesSync to throw")
    } catch {
      // Expected.
    }

    try await Self.assertCategoryScenarioUnchanged(database: database, fixture: fixture)
  }

  // MARK: - Account scenario

  private struct AccountFixture {
    let accountId: UUID
    let legId: UUID
  }

  private static func seedAccountScenario(in database: any DatabaseWriter) async throws
    -> AccountFixture
  {
    let fixture = AccountFixture(accountId: UUID(), legId: UUID())
    let txId = UUID()
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden)
            VALUES (?, 'account-1', 'Checking', 'bank', 'USD', 0, 0);
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, account_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, ?, 'USD', 100, 'expense', 0);
          CREATE TRIGGER force_failure BEFORE DELETE ON account
          BEGIN
            SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """,
        arguments: [
          fixture.accountId, txId, fixture.legId, txId, fixture.accountId,
        ])
    }
    return fixture
  }

  private static func assertAccountScenarioUnchanged(
    database: any DatabaseReader, fixture: AccountFixture
  ) async throws {
    try await database.read { database in
      let legAccountCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND account_id = ?",
          arguments: [fixture.legId, fixture.accountId]) ?? -1
      #expect(legAccountCount == 1, "transaction_leg.account_id null-set must roll back")

      let accountCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM account WHERE id = ?",
          arguments: [fixture.accountId]) ?? -1
      #expect(accountCount == 1, "parent account must still exist")
    }
  }

  // MARK: - Earmark scenario

  private struct EarmarkFixture {
    let earmarkId: UUID
    let budgetId: UUID
    let legId: UUID
  }

  private static func seedEarmarkScenario(in database: any DatabaseWriter) async throws
    -> EarmarkFixture
  {
    let fixture = EarmarkFixture(earmarkId: UUID(), budgetId: UUID(), legId: UUID())
    let categoryId = UUID()
    let txId = UUID()
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO category (id, record_name, name) VALUES (?, 'cat-1', 'Food');
          INSERT INTO earmark (id, record_name, name, position, is_hidden)
            VALUES (?, 'earmark-1', 'Holiday', 0, 0);
          INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
            VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, earmark_id, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', ?, 0);
          CREATE TRIGGER force_failure BEFORE DELETE ON earmark
          BEGIN
            SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """,
        arguments: [
          categoryId, fixture.earmarkId, fixture.budgetId, fixture.earmarkId, categoryId,
          txId, fixture.legId, txId, fixture.earmarkId,
        ])
    }
    return fixture
  }

  private static func assertEarmarkScenarioUnchanged(
    database: any DatabaseReader, fixture: EarmarkFixture
  ) async throws {
    try await database.read { database in
      let budgetCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE id = ?",
          arguments: [fixture.budgetId]) ?? -1
      #expect(budgetCount == 1, "earmark_budget_item delete must roll back")

      let legEarmarkCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND earmark_id = ?",
          arguments: [fixture.legId, fixture.earmarkId]) ?? -1
      #expect(legEarmarkCount == 1, "transaction_leg.earmark_id null-set must roll back")

      let earmarkCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark WHERE id = ?",
          arguments: [fixture.earmarkId]) ?? -1
      #expect(earmarkCount == 1, "parent earmark must still exist")
    }
  }

  // MARK: - Category scenario

  private struct CategoryFixture {
    let categoryId: UUID
    let childCategoryId: UUID
    let budgetId: UUID
    let legId: UUID
  }

  private static func seedCategoryScenario(in database: any DatabaseWriter) async throws
    -> CategoryFixture
  {
    let fixture = CategoryFixture(
      categoryId: UUID(), childCategoryId: UUID(), budgetId: UUID(), legId: UUID())
    let earmarkId = UUID()
    let txId = UUID()
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO category (id, record_name, name) VALUES (?, 'cat-1', 'Food');
          INSERT INTO category (id, record_name, name, parent_id)
            VALUES (?, 'cat-2', 'Groceries', ?);
          INSERT INTO earmark (id, record_name, name, position, is_hidden)
            VALUES (?, 'earmark-1', 'Holiday', 0, 0);
          INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
            VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, category_id, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', ?, 0);
          CREATE TRIGGER force_failure BEFORE DELETE ON category
          BEGIN
            SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """,
        arguments: [
          fixture.categoryId, fixture.childCategoryId, fixture.categoryId,
          earmarkId, fixture.budgetId, earmarkId, fixture.categoryId,
          txId, fixture.legId, txId, fixture.categoryId,
        ])
    }
    return fixture
  }

  private static func assertCategoryScenarioUnchanged(
    database: any DatabaseReader, fixture: CategoryFixture
  ) async throws {
    try await database.read { database in
      let legCategoryCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND category_id = ?",
          arguments: [fixture.legId, fixture.categoryId]) ?? -1
      #expect(legCategoryCount == 1, "transaction_leg.category_id null-set must roll back")

      let budgetCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE id = ?",
          arguments: [fixture.budgetId]) ?? -1
      #expect(budgetCount == 1, "earmark_budget_item delete must roll back")

      let childParentCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM category WHERE id = ? AND parent_id = ?",
          arguments: [fixture.childCategoryId, fixture.categoryId]) ?? -1
      #expect(childParentCount == 1, "child category parent_id null-set must roll back")

      let categoryCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM category WHERE id = ?",
          arguments: [fixture.categoryId]) ?? -1
      #expect(categoryCount == 1, "parent category must still exist")
    }
  }
}
