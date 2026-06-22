// MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Repository sync delete cascades")
struct RepositorySyncCascadeTests {
  /// Builds a `GRDBTransactionRepository` with the shared-registry
  /// resolver / registrar wiring shared by every test in this suite.
  private func makeTxnRepo(
    _ database: any DatabaseWriter
  ) throws -> GRDBTransactionRepository {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    return GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
  }

  /// `applyRemoteChangesSync(saved: [], deleted: [accountId])` must
  /// also remove `investment_value` rows for that account and null
  /// `transaction_leg.account_id` references — replacing what the v4
  /// FK CASCADE / SET NULL did before v5 dropped the FKs.
  @Test
  func accountSyncDeleteCascadesToInvestmentValuesAndNullsLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let accountRepo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let accountId = UUID()
    let legId = UUID()
    let txId = UUID()
    let ivId = UUID()

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
          INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id)
            VALUES (?, 'iv-1', ?, '2026-01-01', 100000, 'USD');
          """,
        arguments: [accountId, txId, legId, txId, accountId, ivId, accountId])
    }

    // Hard-delete via sync path.
    try accountRepo.applyRemoteChangesSync(saved: [], deleted: [accountId])

    try await database.read { database in
      let ivCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM investment_value WHERE account_id = ?",
          arguments: [accountId]) ?? -1
      #expect(ivCount == 0)

      let nulledLegs =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND account_id IS NULL",
          arguments: [legId]) ?? -1
      #expect(nulledLegs == 1)
    }
  }

  @Test
  func transactionDomainDeleteRemovesLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = try makeTxnRepo(database)
    let txId = UUID()
    let leg1Id = UUID()
    let leg2Id = UUID()

    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-2', ?, 'USD', -100, 'transfer', 1);
          """,
        arguments: [txId, leg1Id, txId, leg2Id, txId])
    }

    try await txRepo.delete(id: txId)

    try await database.read { database in
      let legCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
          arguments: [txId]) ?? -1
      #expect(legCount == 0)
    }
  }

  @Test
  func transactionSyncDeleteRemovesLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = try makeTxnRepo(database)
    let txId = UUID()
    let legId = UUID()

    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
          """,
        arguments: [txId, legId, txId])
    }

    try txRepo.applyRemoteChangesSync(saved: [], deleted: [txId])

    try await database.read { database in
      let legCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
          arguments: [txId]) ?? -1
      #expect(legCount == 0)
    }
  }

  /// `applyRemoteChangesSync(saved: [], deleted: [earmarkId])` must
  /// also delete `earmark_budget_item` rows for that earmark and null
  /// `transaction_leg.earmark_id` references — replacing what the v3
  /// FK CASCADE / SET NULL did before v5 dropped the FKs.
  @Test
  func earmarkSyncDeleteCascadesBudgetItemsAndNullsLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database, defaultInstrument: .AUD,
      instrumentResolver: (try SharedRegistryTestSupport.makeSharedRegistry()))
    let earmarkId = UUID()
    let categoryId = UUID()
    let budgetId = UUID()
    let txId = UUID()
    let legId = UUID()

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
          """,
        arguments: [
          categoryId, earmarkId, budgetId, earmarkId, categoryId,
          txId, legId, txId, earmarkId,
        ])
    }

    try earmarkRepo.applyRemoteChangesSync(saved: [], deleted: [earmarkId])

    try await database.read { database in
      let budgetCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE earmark_id = ?",
          arguments: [earmarkId]) ?? -1
      #expect(budgetCount == 0)

      let nulledLeg =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND earmark_id IS NULL",
          arguments: [legId]) ?? -1
      #expect(nulledLeg == 1)
    }
  }

  /// `performSetBudget` must NOT insert a stub `category` row when the
  /// category doesn't exist yet — the schema enforces no FK that would
  /// require it.
  @Test
  func setBudgetToleratesUnknownCategoryWithoutStubInsert() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database, defaultInstrument: .USD,
      instrumentResolver: (try SharedRegistryTestSupport.makeSharedRegistry()))
    let earmarkId = UUID()
    let unknownCategoryId = UUID()

    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO earmark (id, record_name, name, position, is_hidden, instrument_id)
            VALUES (?, 'earmark-1', 'Holiday', 0, 0, 'USD');
          """,
        arguments: [earmarkId])
    }

    let amount = InstrumentAmount(quantity: 5000, instrument: .USD)
    try await earmarkRepo.setBudget(
      earmarkId: earmarkId, categoryId: unknownCategoryId, amount: amount)

    try await database.read { database in
      let categoryCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM category",
          arguments: []) ?? -1
      #expect(categoryCount == 0, "Expected no stub category row now that the FK is gone")

      let budgetCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE earmark_id = ?",
          arguments: [earmarkId]) ?? -1
      #expect(budgetCount == 1)
    }
  }

  /// Applying a CKRecord-equivalent leg upsert whose `account_id` /
  /// `category_id` / `earmark_id` reference rows that don't yet exist
  /// must NOT create blank-name stub rows. The FK-driven stub insertion
  /// in `ensureFKTargets` is removed; only the non-fiat instrument
  /// insertion survives.
  @Test
  func legUpsertWithMissingParentsDoesNotCreatePhantomRows() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = try makeTxnRepo(database)

    let orphanAccountId = UUID()
    let orphanCategoryId = UUID()
    let orphanEarmarkId = UUID()

    // No instrument seed: `.AUD` is an ambient fiat instrument resolved
    // via the shared registry / fiat fallback, and there is no
    // per-profile `instrument` table.
    let txId = UUID()
    let leg = TransactionLeg(
      accountId: orphanAccountId,
      instrument: .AUD,
      quantity: -500,
      type: .expense,
      categoryId: orphanCategoryId,
      earmarkId: orphanEarmarkId)
    let transaction = Transaction(
      id: txId,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [leg])

    _ = try await txRepo.create(transaction)

    try await database.read { database in
      let accountCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM account WHERE id = ?",
          arguments: [orphanAccountId]) ?? -1
      #expect(accountCount == 0, "Expected no phantom account; found \(accountCount)")

      let categoryCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM category WHERE id = ?",
          arguments: [orphanCategoryId]) ?? -1
      #expect(categoryCount == 0, "Expected no phantom category; found \(categoryCount)")

      let earmarkCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark WHERE id = ?",
          arguments: [orphanEarmarkId]) ?? -1
      #expect(earmarkCount == 0, "Expected no phantom earmark; found \(earmarkCount)")
    }
  }
}
