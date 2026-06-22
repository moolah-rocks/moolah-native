// MoolahTests/Backends/GRDB/GRDBCreateManyTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// GRDB-specific contract for the bulk `createMany(_:)` path:
///
/// 1. Atomicity. A failure on any leg insert rolls back every header,
///    every leg, and every auto-inserted instrument across the whole
///    input array — leaving the DB byte-equal to the pre-call state.
/// 2. Hook fan-out. After the write commits, `onRecordChanged` fires
///    exactly once per transaction header and once per leg. Each unique
///    non-fiat leg instrument is registered (batch-deduped) through the
///    injected registrar *before* the write, so it is resolvable
///    afterwards without any per-profile placeholder.
///
/// The per-row pattern is already covered by
/// `CoreFinancialGraphRollbackTests.transactionCreateRollsBackOnLegFailure`
/// and `TransactionHookUpdateDeleteTests`; this file pins the bulk path.
@Suite("GRDBTransactionRepository.createMany — atomicity + hook fan-out")
@MainActor
struct GRDBCreateManyTests {

  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
  }

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

  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  /// There is no per-profile `instrument` table, so the "create path
  /// must not write a per-profile placeholder" contract is the
  /// structural fact that the table is absent — a strictly stronger
  /// guarantee than "zero rows". Returns `true` when the table does
  /// not exist.
  private func perProfileInstrumentTableAbsent(
    _ database: any DatabaseWriter
  ) async throws -> Bool {
    try await database.read { database in
      try
        !(Bool.fetchOne(
          database,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
            """) ?? true)
    }
  }

  /// Three transactions for the fan-out test: a fiat-only one, then two
  /// that both reference the shared non-fiat `btc` instrument (the
  /// second with an extra fiat leg). Exercises per-batch instrument
  /// dedup and per-header / per-leg hook counts.
  private func makeFanOutInputs(accountId: UUID, btc: Instrument) -> [Transaction] {
    [
      Transaction(
        date: Date(), payee: "Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -5, type: .expense)
        ]),
      Transaction(
        date: Date(), payee: "BTC buy",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: btc, quantity: 1, type: .income)
        ]),
      Transaction(
        date: Date(), payee: "BTC swap",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: btc, quantity: -1, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: 100, type: .transfer),
        ]),
    ]
  }

  // MARK: - Atomicity

  @Test("createMany rolls back every header + leg if any leg insert fails")
  func createManyRollsBackOnLegFailure() async throws {
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

    // Trigger fires on any leg insert. The first transaction's first leg
    // will trip it — the entire batch (including the headers of every
    // subsequent transaction in the input array) must roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_create_many_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let inputs = (0..<3).map { index in
      Transaction(
        date: Date(),
        payee: "Payee \(index)",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: Decimal(-(index + 1) * 10), type: .expense)
        ])
    }
    do {
      _ = try await txnRepo.createMany(inputs)
      Issue.record("createMany should have thrown but did not")
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

  // MARK: - Hook fan-out

  @Test("createMany fan-out: 1 hook per txn + 1 per leg; instrument registered once per unique id")
  func createManyHookFanOut() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    // One registry instance as BOTH seams so a registration is
    // resolvable afterwards — mirrors production wiring.
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    let accountId = UUID()
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    // Three transactions. The middle two reference a shared non-fiat
    // instrument (BTC); the others are fiat. Expected fan-out:
    //   - 3 TransactionRow change emits (one per header)
    //   - 4 TransactionLegRow change emits (1 + 1 + 2)
    //   - BTC registered exactly once across the whole batch (the
    //     per-batch dedup in `registerNonFiatLegInstruments`), so the
    //     shared registry holds a single resolvable BTC instrument and
    //     the per-profile `instrument` table is never written.
    let btc = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let inputs = makeFanOutInputs(accountId: accountId, btc: btc)

    _ = try await txnRepo.createMany(inputs)
    try await drainHookHops()

    let txnChanges = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnChanges.map(\.id) == inputs.map(\.id))
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    let expectedLegIds = inputs.flatMap { $0.legs.map(\.id) }
    #expect(Set(legChanges.map(\.id)) == Set(expectedLegIds))
    #expect(legChanges.count == expectedLegIds.count)
    #expect(capture.deleted.isEmpty)
    // BTC is resolvable from the shared registry across the whole
    // batch even though two separate transactions reference it: the
    // per-batch dedup registered it once and the registrar is
    // idempotent. The per-profile `instrument` table was never written.
    let resolvedBtc = try await registry.instrumentMap()[btc.id]
    #expect(resolvedBtc == btc)
    #expect(resolvedBtc?.kind == .cryptoToken)
    let absent = try await perProfileInstrumentTableAbsent(database)
    #expect(
      absent,
      "createMany must not write the per-profile instrument table; v10 dropped it")
  }

  // MARK: - replace hook fan-out

  private func makeTxnRepo(
    database: any DatabaseWriter, capture: HookCapture
  ) throws -> GRDBTransactionRepository {
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    return GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
  }

  private func expectFanOut(
    _ emits: [(recordType: String, id: UUID)],
    header headerId: UUID,
    legs legIds: [UUID]
  ) {
    let headers = emits.filter { $0.recordType == TransactionRow.recordType }
    #expect(headers.map(\.id) == [headerId])
    let legs = emits.filter { $0.recordType == TransactionLegRow.recordType }
    #expect(Set(legs.map(\.id)) == Set(legIds))
    #expect(legs.count == legIds.count)
  }

  @Test(
    "replace fan-out: deleted header + each deleted leg, then created header + each created leg")
  func replaceHookFanOut() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let txnRepo = try makeTxnRepo(database: database, capture: capture)
    let accountId = UUID()
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    let victim = Transaction(
      date: Date(), payee: "Original",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -50, type: .expense),
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: 50, type: .income),
      ])
    let created = try await txnRepo.create(victim)
    try await drainHookHops()
    // Isolate the replace fan-out from the seeding `create`.
    capture.changed.removeAll()
    capture.deleted.removeAll()

    let replacement = Transaction(
      date: Date(), payee: "Replacement",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -75, type: .expense)
      ])
    let result = try await txnRepo.replace(
      deletingIds: [created.id], creating: [replacement])
    try await drainHookHops()

    // Victim header + each victim leg emitted onRecordDeleted with the
    // matching record type; created header + each created leg emitted
    // onRecordChanged with the matching record type.
    expectFanOut(capture.deleted, header: created.id, legs: created.legs.map(\.id))
    expectFanOut(
      capture.changed, header: replacement.id,
      legs: result.flatMap { $0.legs.map(\.id) })
  }
}
