import Foundation
import GRDB
import Testing

@testable import Moolah

// Suite is intentionally non-isolated. The tests are `async throws` and
// touch no main-actor state, so adding `@MainActor` would be a no-op.
// `applyRemoteChangesSync` itself is synchronous — its file-header
// comment in `GRDBTransactionLegRepository.swift` documents that it is
// called from the CKSyncEngine delegate executor in production.
@Suite("TransactionLeg sync ingestion semantics")
struct TransactionLegSyncSemanticTests {

  @Test("applyRemoteChangesSync with same-id leg row is idempotent — no duplicate")
  func sameLegIdUpsertIsIdempotent() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let legRepo = GRDBTransactionLegRepository(database: database)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Rent",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-1000), type: .expense)
        ]))
    let originalLegId = txn.legs[0].id

    // Simulate the server re-delivering the same leg (e.g. a re-fetch
    // after a network blip, or the originating device's own queued
    // record bouncing back). Same id ⇒ upsert lands on the existing row.
    let phantomRow = TransactionLegRow(
      id: originalLegId,
      recordName: TransactionLegRow.recordName(for: originalLegId),
      transactionId: txn.id,
      accountId: accountId,
      instrumentId: Instrument.defaultTestInstrument.id,
      quantity:
        InstrumentAmount(
          quantity: Decimal(-1000), instrument: Instrument.defaultTestInstrument
        ).storageValue,
      type: TransactionType.expense.rawValue,
      categoryId: nil, earmarkId: nil, sortOrder: 0,
      encodedSystemFields: nil, externalId: nil, counterpartyAddress: nil)
    try legRepo.applyRemoteChangesSync(saved: [phantomRow], deleted: [])

    let reloaded = try #require(try await fetchTransaction(txn.id, via: txnRepo))
    #expect(
      reloaded.legs.count == 1,
      "Same-id re-delivery must not duplicate legs — count was \(reloaded.legs.count)")
    #expect(reloaded.legs[0].id == originalLegId)
  }

  @Test(
    "applyRemoteChangesSync with a different-id orphan leg lands as a second row — documents residual race"
  )
  func differentIdOrphanLandsAsSecondRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let legRepo = GRDBTransactionLegRepository(database: database)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Rent",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-1000), type: .expense)
        ]))

    // A server-side orphan with a UUID that the local row does NOT
    // share. Under the stable-id design this can only happen if a
    // "leg removed from transaction" delete-uplink failed and the
    // orphan stays on the server with a uuid the device never owned.
    // Stable ids make this less likely (re-queued deletes hit the
    // right record) but do not make it impossible. The user resolves
    // manually (design Section 7).
    let orphanId = UUID()
    let orphanRow = TransactionLegRow(
      id: orphanId,
      recordName: TransactionLegRow.recordName(for: orphanId),
      transactionId: txn.id,
      accountId: accountId,
      instrumentId: Instrument.defaultTestInstrument.id,
      quantity:
        InstrumentAmount(
          quantity: Decimal(-1000), instrument: Instrument.defaultTestInstrument
        ).storageValue,
      type: TransactionType.expense.rawValue,
      categoryId: nil, earmarkId: nil, sortOrder: 1,
      encodedSystemFields: nil, externalId: nil, counterpartyAddress: nil)
    try legRepo.applyRemoteChangesSync(saved: [orphanRow], deleted: [])

    let reloaded = try #require(try await fetchTransaction(txn.id, via: txnRepo))
    #expect(
      reloaded.legs.count == 2,
      "Different-id orphan must land as a second row — documents residual race")
  }

  @Test("applyRemoteChangesSync rolls back when an upsert in the batch fails")
  func applyRemoteChangesSyncRollsBackOnFailure() throws {
    let database = try ProfileDatabase.openInMemory()
    let legRepo = GRDBTransactionLegRepository(database: database)

    // Seed a transaction header + one leg, plus a `BEFORE INSERT` trigger
    // on `transaction_leg` that fires only when `sort_order = 99` so a
    // later good leg can land but the badly-marked leg blows up. The
    // single multi-statement write that batches `[good, bad]` upserts
    // must roll back atomically — neither row may persist.
    let txId = UUID()
    let originalLegId = UUID()
    try seedRollbackFixture(database: database, txId: txId, originalLegId: originalLegId)

    let goodRow = makeRollbackTestLeg(transactionId: txId, quantity: 200, sortOrder: 1)
    let badRow = makeRollbackTestLeg(transactionId: txId, quantity: 300, sortOrder: 99)

    do {
      try legRepo.applyRemoteChangesSync(saved: [goodRow, badRow], deleted: [])
      Issue.record("Expected applyRemoteChangesSync to throw — rollback test cannot proceed")
    } catch {
      // Expected.
    }

    // Only the original seeded leg may remain; the good row must not have
    // been committed.
    try database.read { database in
      let count = try TransactionLegRow.fetchCount(database)
      #expect(count == 1, "Multi-statement write must roll back — good row must not persist")
      let surviving =
        try TransactionLegRow
        .select(TransactionLegRow.Columns.id, as: UUID.self)
        .fetchAll(database)
      #expect(surviving == [originalLegId])
    }
  }

  /// Seeds an instrument + transaction + one leg, then installs a
  /// `BEFORE INSERT` trigger that aborts when `sort_order = 99`. Used by
  /// `applyRemoteChangesSyncRollsBackOnFailure` to force a mid-batch
  /// failure inside the multi-statement write.
  private func seedRollbackFixture(
    database: any DatabaseWriter, txId: UUID, originalLegId: UUID
  ) throws {
    try database.write { database in
      try database.execute(
        sql: """
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-rollback', '2026-01-01');
          INSERT INTO transaction_leg
            (id, record_name, transaction_id, instrument_id,
             quantity, type, sort_order)
            VALUES (?, ?, ?, 'AUD', 100, 'expense', 0);
          CREATE TRIGGER fail_sort_99
          BEFORE INSERT ON transaction_leg
          WHEN NEW.sort_order = 99
          BEGIN
            SELECT RAISE(ABORT, 'forced rollback for sync test');
          END;
          """,
        arguments: [
          txId,
          originalLegId, TransactionLegRow.recordName(for: originalLegId), txId,
        ])
    }
  }

  /// Builds a `TransactionLegRow` for the rollback test. `sortOrder = 99`
  /// is the trigger-armed marker that forces the row's upsert to abort.
  private func makeRollbackTestLeg(
    transactionId: UUID, quantity: Int64, sortOrder: Int
  ) -> TransactionLegRow {
    let legId = UUID()
    return TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: transactionId,
      accountId: nil,
      instrumentId: "AUD",
      quantity: quantity,
      type: TransactionType.expense.rawValue,
      categoryId: nil, earmarkId: nil, sortOrder: sortOrder,
      encodedSystemFields: nil, externalId: nil, counterpartyAddress: nil)
  }

  /// Fetch a single transaction by id via the protocol's `fetchAll(filter:)`.
  /// The `TransactionRepository` protocol does not expose a `fetch(id:)`, so
  /// this helper unfilters and picks by id — mirrors the same pattern in
  /// `GRDBTransactionStableLegIdTests`.
  private func fetchTransaction(
    _ id: UUID, via repo: GRDBTransactionRepository
  ) async throws -> Transaction? {
    let all = try await repo.fetchAll(filter: TransactionFilter())
    return all.first(where: { $0.id == id })
  }
}
