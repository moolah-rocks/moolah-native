// MoolahTests/Backends/GRDB/TransactionDeleteRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Transaction delete is atomic under failure")
struct TransactionDeleteRollbackTests {
  @Test
  func deleteRollsBackOnFailureAfterLegDelete() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let txId = UUID()
    let legId = UUID()

    // BEFORE-DELETE trigger on "transaction" raises ABORT, simulating
    // a write failure mid-transaction. SQL comments inside the literal
    // use `--`, not `//`, otherwise SQLite returns a parse error
    // before the seed completes.
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
          CREATE TRIGGER force_failure BEFORE DELETE ON "transaction"
          BEGIN
            SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """,
        arguments: [txId, legId, txId])
    }

    do {
      try await txRepo.delete(id: txId)
      Issue.record("Expected delete to throw")
    } catch {
      // Expected.
    }

    // Both rows must still exist — the explicit DELETE on transaction_leg
    // ran but the surrounding GRDB transaction must have rolled back.
    try await database.read { database in
      let txCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM \"transaction\" WHERE id = ?",
          arguments: [txId]) ?? -1
      #expect(txCount == 1)

      let legCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ?",
          arguments: [legId]) ?? -1
      #expect(legCount == 1)
    }
  }
}
