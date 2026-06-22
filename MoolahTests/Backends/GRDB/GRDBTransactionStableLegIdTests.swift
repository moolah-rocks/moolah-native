import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBTransactionRepository preserves leg ids across update")
@MainActor
struct GRDBTransactionStableLegIdTests {

  /// Reload a single transaction by id via `fetchAll`, since
  /// `TransactionRepository` exposes only filter/pagination fetches.
  /// Returns `nil` if the row is no longer present.
  private func reload(
    _ repo: any TransactionRepository, id: UUID
  ) async throws -> Transaction? {
    let all = try await repo.fetchAll(filter: TransactionFilter())
    return all.first(where: { $0.id == id })
  }

  @Test("editing only the parent header keeps every leg id stable")
  func headerOnlyEditPreservesLegIds() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId,
        name: "Cash",
        type: .bank,
        instrument: Instrument.defaultTestInstrument,
        positions: []))
    let original = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: -10, type: .expense)
        ]))
    let originalLegIds = original.legs.map(\.id)

    var edited = original
    edited.payee = "Espresso"
    _ = try await backend.transactions.update(edited)

    let reloaded = try await reload(backend.transactions, id: original.id)
    let reloadedLegIds = try #require(reloaded).legs.map(\.id)
    #expect(reloadedLegIds == originalLegIds)
  }

  @Test("removing one leg from a two-leg transaction keeps the surviving leg's id")
  func removeOneLegPreservesSurvivor() async throws {
    let (backend, _) = try TestBackend.create()
    let acctA = UUID()
    let acctB = UUID()
    for id in [acctA, acctB] {
      _ = try await backend.accounts.create(
        Account(
          id: id, name: id.uuidString, type: .bank,
          instrument: Instrument.defaultTestInstrument, positions: []))
    }
    let original = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Move",
        legs: [
          TransactionLeg(
            accountId: acctA, instrument: Instrument.defaultTestInstrument,
            quantity: -50, type: .transfer),
          TransactionLeg(
            accountId: acctB, instrument: Instrument.defaultTestInstrument,
            quantity: 50, type: .transfer),
        ]))
    let survivorId = original.legs[0].id

    var edited = original
    edited.legs = [original.legs[0]]  // drop the second leg
    _ = try await backend.transactions.update(edited)

    let reloaded = try #require(try await reload(backend.transactions, id: original.id))
    #expect(reloaded.legs.map(\.id) == [survivorId])
  }

  @Test("create(_:) writes the caller-supplied leg id, not a fresh UUID")
  func createUsesCallerSuppliedLegId() async throws {
    // Without this test, a regression that leaves
    // `let legId = UUID()` in `create(_:)` (while only fixing
    // `performUpdate`) would not be caught by the round-trip / reorder
    // / remove tests below — those capture `original.legs.map(\.id)`
    // *after* `create`, so they verify update-stability but not
    // create-stability. Pin the create-time id explicitly.
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: Instrument.defaultTestInstrument, positions: []))
    let preassignedLegId = UUID()
    let txn = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Tagged",
        legs: [
          TransactionLeg(
            id: preassignedLegId,
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: -7, type: .expense)
        ]))
    // Returned domain object reflects the caller's id.
    #expect(txn.legs.first?.id == preassignedLegId)
    // Re-fetched row from GRDB also uses the caller's id.
    let reloaded = try #require(try await reload(backend.transactions, id: txn.id))
    #expect(reloaded.legs.map(\.id) == [preassignedLegId])
  }

  @Test("reordering legs rewrites sort_order but keeps ids")
  func reorderRewritesSortOrderKeepsIds() async throws {
    let (backend, _) = try TestBackend.create()
    let acctA = UUID()
    let acctB = UUID()
    for id in [acctA, acctB] {
      _ = try await backend.accounts.create(
        Account(
          id: id, name: id.uuidString, type: .bank,
          instrument: Instrument.defaultTestInstrument, positions: []))
    }
    let original = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Swap",
        legs: [
          TransactionLeg(
            accountId: acctA, instrument: Instrument.defaultTestInstrument,
            quantity: -25, type: .transfer),
          TransactionLeg(
            accountId: acctB, instrument: Instrument.defaultTestInstrument,
            quantity: 25, type: .transfer),
        ]))
    let firstId = original.legs[0].id
    let secondId = original.legs[1].id

    var edited = original
    edited.legs = [original.legs[1], original.legs[0]]  // swap
    _ = try await backend.transactions.update(edited)

    let reloaded = try #require(try await reload(backend.transactions, id: original.id))
    #expect(reloaded.legs.map(\.id) == [secondId, firstId])
  }

  @Test(
    "header-only update preserves each leg's encodedSystemFields blob")
  func headerOnlyEditPreservesEncodedSystemFields() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Coffee",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -10, type: .expense)
        ]))
    let legId = txn.legs[0].id

    // Simulate a successful CK round-trip stamping the leg with its
    // cached system fields blob. `try await` selects the async overload
    // of `DatabaseWriter.write` — calling the synchronous overload from
    // an async test silently blocks the cooperative thread pool.
    let stampedFields = Data([0xCA, 0xFE, 0xBA, 0xBE])
    try await database.write { database in
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == legId)
        .updateAll(
          database,
          [TransactionLegRow.Columns.encodedSystemFields.set(to: stampedFields)])
    }

    // Header-only edit. After Reference R1's preservation pass, the
    // leg's cached blob must survive verbatim — otherwise the next sync
    // pass treats the leg as unsynced and re-uploads it.
    var edited = txn
    edited.payee = "Espresso"
    _ = try await txnRepo.update(edited)

    let reloadedFields: Data? = try await database.read { database in
      // fetchOne on `Data?.self` returns `Data??`; flatMap collapses
      // outer-Optional("row missing") to inner-Optional("blob nil") for
      // a single-layer comparison against `stampedFields`.
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.id == legId)
        .select(TransactionLegRow.Columns.encodedSystemFields, as: Data?.self)
        .fetchOne(database)
        .flatMap { $0 }
    }
    #expect(reloadedFields == stampedFields)
  }

  /// Installs a `BEFORE UPDATE` trigger on the header table that aborts
  /// every header `UPDATE`. The trigger fires inside `performUpdate`'s
  /// write closure after the header `UPDATE` is issued and before any
  /// leg upserts run; SQLite raises ABORT, which propagates out as a
  /// Swift error, and the surrounding `database.write { … }` rolls the
  /// entire transaction back per §5 of DATABASE_CODE_GUIDE. Same
  /// pattern as `TransactionDeleteRollbackTests`.
  private func triggerForcedUpdateFailure(
    on database: any DatabaseWriter
  ) async throws {
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER force_update_failure
          BEFORE UPDATE ON "transaction"
          BEGIN
            SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }
  }

  @Test("performUpdate rolls back the header on a mid-write throw")
  func performUpdateRollsBackHeaderOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Original",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -10, type: .expense)
        ]))

    try await triggerForcedUpdateFailure(on: database)

    var brokenUpdate = txn
    brokenUpdate.payee = "Should not land"

    do {
      _ = try await txnRepo.update(brokenUpdate)
      Issue.record("Expected update to throw — rollback test cannot proceed")
    } catch {
      // Expected: SQLite ABORT propagates out as a Swift error.
    }

    let reloaded = try #require(try await reload(txnRepo, id: txn.id))
    #expect(reloaded.payee == "Original")
  }

  @Test("performUpdate rolls back the legs on a mid-write throw")
  func performUpdateRollsBackLegsOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Original",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -10, type: .expense)
        ]))
    let originalLegId = txn.legs[0].id

    try await triggerForcedUpdateFailure(on: database)

    var brokenUpdate = txn
    brokenUpdate.payee = "Should not land"

    do {
      _ = try await txnRepo.update(brokenUpdate)
      Issue.record("Expected update to throw — rollback test cannot proceed")
    } catch {
      // Expected.
    }

    let reloaded = try #require(try await reload(txnRepo, id: txn.id))
    #expect(reloaded.legs.map(\.id) == [originalLegId])
  }
}
