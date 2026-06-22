import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Transaction replace is atomic under failure")
struct TransactionReplaceRollbackTests {
  @Test
  func replaceRollsBackBothDeleteAndInsertOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let existingId = UUID()
    let existingLegId = UUID()
    let accountId = UUID()
    try await seedSourceAndFailureTrigger(
      in: database,
      existingId: existingId,
      existingLegId: existingLegId,
      accountId: accountId)

    let newTx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: -50,
          type: .expense)
      ])

    do {
      _ = try await txRepo.replace(deletingIds: [existingId], creating: [newTx])
      Issue.record("Expected replace to throw")
    } catch {
      // Expected.
    }

    try await assertNothingChanged(
      in: database,
      existingId: existingId,
      existingLegId: existingLegId,
      newId: newTx.id)
  }

  /// Companion to the delete-phase test: the failure trigger fires on the
  /// CREATE half of `replace`, AFTER the deleted rows have been snapshotted
  /// and removed. Proves the reordered write (snapshot → delete → create)
  /// still rolls back atomically when `performCreateMany` throws — the
  /// snapshotted/deleted source must be restored and the new row absent.
  @Test
  func replaceRollsBackDeleteWhenCreateFails() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let existingId = UUID()
    let existingLegId = UUID()
    let accountId = UUID()
    try await seedSourceAndInsertFailureTrigger(
      in: database,
      existingId: existingId,
      existingLegId: existingLegId,
      accountId: accountId)

    let newTx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: -50,
          type: .expense)
      ])

    do {
      _ = try await txRepo.replace(deletingIds: [existingId], creating: [newTx])
      Issue.record("Expected replace to throw")
    } catch {
      // Expected.
    }

    try await assertNothingChanged(
      in: database,
      existingId: existingId,
      existingLegId: existingLegId,
      newId: newTx.id)
  }

  /// Seeds one source transaction (header + leg) plus a BEFORE-DELETE
  /// trigger that raises ABORT so the `replace` write fails
  /// mid-transaction. SQL comments inside the literal use `--`, not
  /// `//`.
  private func seedSourceAndFailureTrigger(
    in database: any DatabaseWriter,
    existingId: UUID,
    existingLegId: UUID,
    accountId: UUID
  ) async throws {
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-existing', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, account_id,
                                       instrument_id, quantity, type, sort_order)
            VALUES (?, 'leg-existing', ?, ?, 'USD', 100, 'expense', 0);
          CREATE TRIGGER force_failure BEFORE DELETE ON "transaction"
          BEGIN
            SELECT RAISE(ABORT, 'forced failure for replace rollback test');
          END;
          """,
        arguments: [existingId, existingLegId, existingId, accountId])
    }
  }

  /// Seeds one source transaction (header + leg), then installs a
  /// BEFORE-INSERT trigger that raises ABORT. The trigger is created AFTER
  /// the seed inserts (SQLite runs the statements in order), so it fires only
  /// on the `replace`'s create half — exercising rollback of an
  /// already-completed snapshot+delete. SQL comments use `--`, not `//`.
  private func seedSourceAndInsertFailureTrigger(
    in database: any DatabaseWriter,
    existingId: UUID,
    existingLegId: UUID,
    accountId: UUID
  ) async throws {
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-existing', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, account_id,
                                       instrument_id, quantity, type, sort_order)
            VALUES (?, 'leg-existing', ?, ?, 'USD', 100, 'expense', 0);
          CREATE TRIGGER force_insert_failure BEFORE INSERT ON "transaction"
          BEGIN
            SELECT RAISE(ABORT, 'forced create failure for replace rollback test');
          END;
          """,
        arguments: [existingId, existingLegId, existingId, accountId])
    }
  }

  /// The source must survive (delete rolled back) and the new
  /// transaction must NOT have been inserted (insert rolled back).
  private func assertNothingChanged(
    in database: any DatabaseWriter,
    existingId: UUID,
    existingLegId: UUID,
    newId: UUID
  ) async throws {
    try await database.read { database in
      let existingCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM \"transaction\" WHERE id = ?",
          arguments: [existingId]) ?? -1
      #expect(existingCount == 1)

      let existingLegCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ?",
          arguments: [existingLegId]) ?? -1
      #expect(existingLegCount == 1)

      let newCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM \"transaction\" WHERE id = ?",
          arguments: [newId]) ?? -1
      #expect(newCount == 0)
    }
  }
}
