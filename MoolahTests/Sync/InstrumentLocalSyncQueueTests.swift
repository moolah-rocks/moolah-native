import Foundation
import GRDB
import Testing
import os

@testable import Moolah

/// Pins the contract that local mutations which introduce a new non-fiat
/// instrument register it so it (a) becomes resolvable and (b) is queued
/// for CloudKit upload. Without this, instruments created by paths that
/// don't go through `InstrumentRegistryRepository.registerStock /
/// registerCrypto` (e.g. SelfWealth CSV import or any
/// `transactionRepository.create` whose leg references a not-yet-known
/// stock) live only on the device that created them — sibling devices
/// see the legs but no `InstrumentRow`, fall back to
/// `Instrument.fiat(code: id)` in `fetchInstrumentMap`, and route stock
/// conversions through Frankfurter, which 404s.
///
/// Registration routes through the injected `InstrumentRegistering`
/// seam, awaited *before* the per-profile write.
/// Production injects the shared `GRDBInstrumentRegistryRepository`;
/// these tests use the production-shaped wiring (shared registry as
/// `instrumentRegistrar`) and assert the instrument is now both
/// resolvable via the registry's resolver and surfaced by
/// `unsyncedNonFiatRowIdsSync` (the queue the reconciliation /
/// per-record upload path drains).
@Suite("Local mutations register + queue new non-fiat instruments for sync")
struct InstrumentLocalSyncQueueTests {

  // MARK: - Fixtures

  private func makeStockInstrument(ticker: String) -> Instrument {
    Instrument.stock(ticker: "\(ticker).AX", exchange: "ASX", name: ticker)
  }

  private func makeStockLeg(
    instrument: Instrument,
    accountId: UUID,
    quantity: Decimal = 100
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: quantity,
      type: .trade,
      categoryId: nil,
      earmarkId: nil)
  }

  /// Production-shaped wiring: a shared registry over the profile-index
  /// DB is injected as both resolver and registrar; the per-profile
  /// data lands in a separate DB.
  private func makeSharedRegistry() throws -> GRDBInstrumentRegistryRepository {
    GRDBInstrumentRegistryRepository(database: try ProfileIndexDatabase.openInMemory())
  }

  private func sharedRowIds(_ registry: GRDBInstrumentRegistryRepository) throws -> [String] {
    try registry.unsyncedNonFiatRowIdsSync()
  }

  // MARK: - GRDBTransactionRepository.create

  @Test("create registers + queues a new non-fiat leg instrument")
  func createRegistersNewStockLeg() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let stock = makeStockInstrument(ticker: "IFRA")
    let txn = Transaction(
      date: Date(), payee: "Buy IFRA",
      legs: [makeStockLeg(instrument: stock, accountId: UUID())])

    _ = try await repo.create(txn)

    let resolved = try await registry.instrumentMap()[stock.id]
    #expect(resolved == stock)
    #expect(try sharedRowIds(registry) == [stock.id])
  }

  @Test("create does not register fiat legs")
  func createDoesNotRegisterFiatLeg() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let txn = Transaction(
      date: Date(), payee: "Coffee",
      legs: [
        makeContractTestLeg(accountId: UUID(), quantity: -5, type: .expense)
      ])

    _ = try await repo.create(txn)

    #expect(try sharedRowIds(registry).isEmpty)
  }

  @Test("create is idempotent when the instrument is already registered")
  func createIdempotentWhenInstrumentAlreadyRegistered() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let stock = makeStockInstrument(ticker: "VAS")
    // Pre-register with synced system fields so a redundant register
    // would (incorrectly) reset it to unsynced and re-queue it.
    try await registry.registerStock(stock)
    try await registry.database.write { database in
      _ =
        try InstrumentRow
        .filter(InstrumentRow.Columns.id == stock.id)
        .updateAll(database, [InstrumentRow.Columns.encodedSystemFields.set(to: Data(count: 4))])
    }

    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let txn = Transaction(
      date: Date(), payee: "Buy VAS",
      legs: [makeStockLeg(instrument: stock, accountId: UUID())])

    _ = try await repo.create(txn)

    // Still resolvable, and the synced row was not re-queued.
    let resolved = try await registry.instrumentMap()[stock.id]
    #expect(resolved == stock)
    #expect(try sharedRowIds(registry).isEmpty)
  }

  @Test("create dedupes registration for two legs sharing one new instrument")
  func createDedupesRegistrationForRepeatedInstrument() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let stock = makeStockInstrument(ticker: "VGS")
    let accountId = UUID()
    let txn = Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeStockLeg(instrument: stock, accountId: accountId, quantity: 10),
        makeStockLeg(instrument: stock, accountId: accountId, quantity: -5),
      ])

    _ = try await repo.create(txn)

    // Exactly one row for the shared instrument despite two legs.
    #expect(try sharedRowIds(registry) == [stock.id])
    let resolved = try await registry.instrumentMap()[stock.id]
    #expect(resolved == stock)
  }

  // MARK: - GRDBTransactionRepository.update

  @Test("update registers + queues a new non-fiat instrument added to a leg")
  func updateRegistersNewlyAddedStockLeg() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let accountId = UUID()
    let original = Transaction(
      date: Date(), payee: "Setup",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .expense)
      ])
    _ = try await repo.create(original)
    #expect(try sharedRowIds(registry).isEmpty)

    let stock = makeStockInstrument(ticker: "IOZ")
    let updated = Transaction(
      id: original.id,
      date: original.date, payee: "Buy IOZ",
      legs: [makeStockLeg(instrument: stock, accountId: accountId)])
    _ = try await repo.update(updated)

    let resolved = try await registry.instrumentMap()[stock.id]
    #expect(resolved == stock)
    #expect(try sharedRowIds(registry) == [stock.id])
  }

  // MARK: - GRDBAccountRepository.create

  @Test("account create registers + queues a new non-fiat account instrument")
  func accountCreateRegistersNewStockAccountInstrument() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let stock = makeStockInstrument(ticker: "VAP")
    let account = Account(name: "VAP Holdings", type: .investment, instrument: stock)

    _ = try await repo.create(account)

    let resolved = try await registry.instrumentMap()[stock.id]
    #expect(resolved == stock)
    #expect(try sharedRowIds(registry) == [stock.id])
  }

  @Test("account create does not register fiat accounts")
  func accountCreateDoesNotRegisterFiatAccount() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let account = Account(name: "Cash", type: .bank, instrument: .defaultTestInstrument)
    _ = try await repo.create(account)

    #expect(try sharedRowIds(registry).isEmpty)
  }

  @Test("account create is idempotent when the instrument is already registered")
  func accountCreateIdempotentWhenInstrumentAlreadyRegistered() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()
    let stock = makeStockInstrument(ticker: "VGS")
    try await registry.registerStock(stock)
    try await registry.database.write { database in
      _ =
        try InstrumentRow
        .filter(InstrumentRow.Columns.id == stock.id)
        .updateAll(database, [InstrumentRow.Columns.encodedSystemFields.set(to: Data(count: 4))])
    }

    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let account = Account(name: "VGS Holdings", type: .investment, instrument: stock)
    _ = try await repo.create(account)

    let resolved = try await registry.instrumentMap()[stock.id]
    #expect(resolved == stock)
    #expect(try sharedRowIds(registry).isEmpty)
  }

  // MARK: - create → fireOnRecordChanged chain

  /// Pins the end-to-end chain:
  ///   `repo.create` → `registerResolvable` → `registerCrypto`
  ///   → `fireOnRecordChanged` → `attachSyncHooks` callback.
  ///
  /// The `attachSyncHooks` call replaces the no-op closures from
  /// `GRDBInstrumentRegistryRepository.init` with the capturing closures;
  /// this mirrors the production pattern where `SyncCoordinator` rotates
  /// real hooks in after boot. The hook fires exactly once per distinct
  /// new instrument, so the capture must contain exactly that instrument's
  /// id string.
  @Test("create fires onRecordChanged exactly once for a new crypto leg via attachSyncHooks")
  func createFiresOnRecordChangedForNewCryptoLegViaAttachSyncHooks() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try makeSharedRegistry()

    // OSAllocatedUnfairLock guards concurrent writes: `fireOnRecordChanged`
    // is called from the GRDB write queue, not @MainActor.
    let capturedIds = OSAllocatedUnfairLock<[String]>(initialState: [])
    registry.attachSyncHooks(
      onRecordChanged: { id in capturedIds.withLock { $0.append(id) } },
      onRecordDeleted: { _ in })

    let repo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let txn = Transaction(
      date: Date(), payee: "Buy ETH",
      legs: [makeStockLeg(instrument: eth, accountId: UUID())])

    _ = try await repo.create(txn)

    let fired = capturedIds.withLock { $0 }
    #expect(
      fired == [eth.id], "onRecordChanged must fire exactly once with the crypto instrument id")
  }

  // MARK: - Reconciliation: existing unsynced non-fiat rows

  @Test("unsyncedNonFiatRowIdsSync returns non-fiat rows with null encoded_system_fields")
  func unsyncedNonFiatRowIdsSyncReturnsUnsyncedStocks() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let stock = Instrument.stock(ticker: "IFRA.AX", exchange: "ASX", name: "IFRA")
    try await database.write { database in
      try InstrumentRow(domain: stock).insert(database)
    }
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let ids = try registry.unsyncedNonFiatRowIdsSync()

    #expect(ids == [stock.id])
  }

  @Test("unsyncedNonFiatRowIdsSync excludes rows whose encoded_system_fields is non-null")
  func unsyncedNonFiatRowIdsSyncExcludesSyncedRows() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let stock = Instrument.stock(ticker: "IOZ.AX", exchange: "ASX", name: "IOZ")
    try await database.write { database in
      var row = InstrumentRow(domain: stock)
      row.encodedSystemFields = Data(count: 4)  // sentinel: anything non-nil
      try row.insert(database)
    }
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let ids = try registry.unsyncedNonFiatRowIdsSync()

    #expect(ids.isEmpty)
  }

  @Test("unsyncedNonFiatRowIdsSync excludes fiat rows even when unsynced")
  func unsyncedNonFiatRowIdsSyncExcludesFiat() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    // Synthetic fiat rows aren't normally written, but the migration
    // boundary means a stale row might exist; the helper must filter
    // them out so the reconciliation pass doesn't try to upload AUD.
    try await database.write { database in
      try InstrumentRow(domain: .AUD).insert(database)
    }
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let ids = try registry.unsyncedNonFiatRowIdsSync()

    #expect(ids.isEmpty)
  }
}
