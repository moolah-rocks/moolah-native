import Foundation
import GRDB

@testable import Moolah

/// Wraps `database.write` and traps with a clear message on failure.
///
/// In-memory GRDB writes during test seeding should never fail; a
/// failure here means the test harness is broken and the suite cannot
/// proceed. Trapping keeps seed call sites free of `try!` without
/// forcing every seed helper (and its hundreds of callers) to throw.
///
/// Marked `nonisolated` so the synchronous GRDB write doesn't block
/// the main actor when callers happen to be `@MainActor`-isolated test
/// methods. The GRDB queue mediates concurrent access internally; the
/// only state this helper touches is the (`Sendable`) database handle.
nonisolated private func writeOrTrap(
  _ database: any DatabaseWriter,
  file: StaticString = #file,
  line: UInt = #line,
  _ block: (Database) throws -> Void
) {
  do {
    try database.write(block)
  } catch {
    preconditionFailure(
      "TestBackend seed write failed: \(error)",
      file: file,
      line: line
    )
  }
}

/// Factory for creating CloudKitBackend instances backed by an in-memory GRDB database.
/// Used in all tests as a replacement for InMemoryBackend and individual InMemory*Repository types.
enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory GRDB database.
  /// Each call creates a fresh, isolated queue — no cross-test contamination.
  ///
  /// `sharedRegistry` lets a test pin the same shared
  /// `GRDBInstrumentRegistryRepository` across multiple backends so
  /// cross-profile sharing is observable in test (matches production's
  /// `SyncCoordinator.sharedInstrumentRegistry`). When omitted, each
  /// call constructs a fresh registry against its own in-memory
  /// profile-index DB (`SharedRegistryTestSupport.makeSharedRegistry()`)
  /// — the test-time analogue of production's shared registry. It is
  /// never pointed at the per-profile `ProfileDatabase`: there is no
  /// per-profile `instrument` table, so instrument identity lives only
  /// on the profile-index registry.
  ///
  /// The backend's `grdbInstruments` is the exact registry instance its
  /// repositories resolve and register through. Tests that seed a
  /// non-fiat denomination directly (bypassing the create path) register
  /// it there via `TestBackend.register(_:in:)` so it is resolvable on
  /// read-back, mirroring how production's create path registers via the
  /// same registry.
  static func create(
    instrument: Instrument = .defaultTestInstrument,
    exchangeRates: [String: [String: Decimal]] = [:],
    sharedRegistry: GRDBInstrumentRegistryRepository? = nil
  ) throws -> (backend: CloudKitBackend, database: DatabaseQueue) {
    let rateClient = FixedRateClient(rates: exchangeRates)
    // The per-profile `data.sqlite` carries domain rows and the two
    // synced csv-import tables. Instrument identity and the rate /
    // price caches live solely on the shared profile-index DB, not
    // here. This mirrors production, where
    // `SyncCoordinator.sharedMarketData` and the shared registry are
    // both pointed at `ProfileContainerManager.profileIndexDatabase`.
    let database = try ProfileDatabase.openInMemory()
    let registry =
      try sharedRegistry
      ?? SharedRegistryTestSupport.makeSharedRegistry()
    // The rate / price caches share the registry's profile-index DB,
    // exactly as production shares one profile-index DB across the
    // shared registry and `sharedMarketData`.
    let marketDataDatabase = registry.database
    // Pin to UTC so tests that build fixture date keys with UTC
    // formatters (e.g. `Date().iso8601DateOnlyString`) line up with the
    // cap's "yesterday" regardless of the host machine's local zone.
    let utc = TimeZone(identifier: "UTC") ?? .current
    let exchangeRateService = ExchangeRateService(
      client: rateClient, database: marketDataDatabase, timeZone: utc)
    let conversionService = FiatConversionService(
      exchangeRates: exchangeRateService,
      database: marketDataDatabase)
    let backend = CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: "Test",
      conversionService: conversionService,
      instrumentRegistry: registry
    )
    return (backend, database)
  }

  /// Registers a non-fiat instrument into the backend's shared
  /// profile-index registry so it resolves on read-back.
  ///
  /// `seed(transactions:)` and friends materialise FK / cascade
  /// structure by writing raw Rows; they cannot write a non-fiat
  /// `instrument` row because there is no per-profile `instrument`
  /// table. Instrument identity lives solely on the profile-index
  /// registry, so a test that seeds a stock / crypto leg must register
  /// its denomination here — the same `InstrumentRegistering` seam
  /// production's create path uses. Fiat is ambient (resolved from ISO
  /// data) and a no-op here.
  static func register(
    _ instrument: Instrument,
    in backend: CloudKitBackend
  ) async throws {
    try await backend.grdbInstruments.registerResolvable(instrument)
  }

  // MARK: - Data Seeding

  /// Seeds accounts into the in-memory store. Uses `upsert` so a
  /// previously-inserted placeholder (e.g. one auto-created by
  /// `seed(transactions:)`) is overwritten with the test's intended row
  /// rather than colliding on `account.record_name`'s UNIQUE constraint.
  @discardableResult
  static func seed(
    accounts: [Account],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Account] {
    writeOrTrap(database) { database in
      for account in accounts {
        try AccountRow(domain: account).upsert(database)
      }
    }
    return accounts
  }

  /// Seeds accounts with opening balances into the in-memory store.
  /// Creates opening balance transactions for accounts with the provided balances.
  /// `upsert` mirrors `seed(accounts:)` so placeholder rows from earlier
  /// `seed(transactions:)` calls don't collide on `record_name`.
  @discardableResult
  static func seed(
    accounts: [(account: Account, openingBalance: InstrumentAmount)],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Account] {
    writeOrTrap(database) { database in
      for (account, openingBalance) in accounts {
        try AccountRow(domain: account).upsert(database)
        if !openingBalance.isZero {
          try insertOpeningBalanceTransaction(
            database: database,
            accountId: account.id,
            instrument: instrument,
            openingBalance: openingBalance)
        }
      }
    }
    return accounts.map(\.account)
  }

  private static func insertOpeningBalanceTransaction(
    database: Database,
    accountId: UUID,
    instrument: Instrument,
    openingBalance: InstrumentAmount
  ) throws {
    let txnId = UUID()
    let txnRow = TransactionRow(
      id: txnId,
      recordName: TransactionRow.recordName(for: txnId),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    try txnRow.insert(database)
    let legId = UUID()
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: accountId,
      instrumentId: instrument.id,
      quantity: openingBalance.storageValue,
      type: TransactionType.openingBalance.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    try legRow.insert(database)
  }

  /// Seeds transactions into the in-memory store.
  ///
  /// Non-fiat denominations are NOT auto-registered: instrument identity
  /// lives on the profile-index registry (there is no per-profile
  /// `instrument` table). A test
  /// seeding a stock / crypto leg must register it via
  /// `TestBackend.register(_:in:)` so the resolver resolves it on
  /// read-back; fiat is ambient and needs no registration.
  @discardableResult
  static func seed(
    transactions: [Transaction],
    in database: any DatabaseWriter
  ) -> [Transaction] {
    writeOrTrap(database) { database in
      var seen = TransactionSeedState()
      for txn in transactions {
        try TransactionRow(domain: txn).insert(database)
        for (index, leg) in txn.legs.enumerated() {
          try ensureLegParents(database: database, leg: leg, seen: &seen)
          try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: index)
            .insert(database)
        }
      }
    }
    return transactions
  }

  /// Tracks which placeholder rows have already been materialised inside
  /// a single `seed(transactions:)` call so the per-leg helper doesn't
  /// re-issue an `INSERT` for the same parent.
  private struct TransactionSeedState {
    var accounts: Set<UUID> = []
    var categories: Set<UUID> = []
    var earmarks: Set<UUID> = []
  }

  /// Materialises placeholder parents (`account`, `category`,
  /// `earmark`) referenced by a single leg, if any of them are missing
  /// in the test database.
  ///
  /// Convenience for tests that rarely pre-seed parents before legs
  /// that reference them. The schema does not enforce FKs
  /// (`v5_drop_foreign_keys`); the helper lets those tests read back
  /// fully-resolved domain `Transaction` values with non-trivial parent
  /// rows for assertion purposes. Tests that care about a specific
  /// parent shape seed it explicitly; the `ensurePlaceholder*` helpers
  /// respect existing rows.
  ///
  /// It does **not** materialise an `instrument` row: there is no
  /// per-profile `instrument` table, so instrument identity lives only
  /// on the profile-index registry. A test that seeds a non-fiat leg
  /// must register its denomination via `TestBackend.register(_:in:)`
  /// so the resolver (the shared registry) resolves it on read-back —
  /// fiat is ambient and needs no registration.
  private static func ensureLegParents(
    database: Database,
    leg: TransactionLeg,
    seen: inout TransactionSeedState
  ) throws {
    if let accountId = leg.accountId, !seen.accounts.contains(accountId) {
      seen.accounts.insert(accountId)
      try ensurePlaceholderAccount(
        database: database, id: accountId, instrument: leg.instrument)
    }
    if let categoryId = leg.categoryId, !seen.categories.contains(categoryId) {
      seen.categories.insert(categoryId)
      try ensurePlaceholderCategory(database: database, id: categoryId)
    }
    if let earmarkId = leg.earmarkId, !seen.earmarks.contains(earmarkId) {
      seen.earmarks.insert(earmarkId)
      try ensurePlaceholderEarmark(
        database: database, id: earmarkId, instrument: leg.instrument)
    }
  }

  /// Inserts a stub `account` row keyed by `id` if one isn't already
  /// present. Used by the seed helpers so tests can read back
  /// fully-resolved domain values for legs / investment-values that
  /// reference an account the test didn't bother to seed (most existing
  /// tests rely on this implicit behaviour from the SwiftData era).
  private static func ensurePlaceholderAccount(
    database: Database, id: UUID, instrument: Instrument
  ) throws {
    let exists = try AccountRow.filter(AccountRow.Columns.id == id).fetchOne(database)
    guard exists == nil else { return }
    let stub = Account(
      id: id, name: "stub", type: .bank, instrument: instrument)
    try AccountRow(domain: stub).insert(database)
  }

  /// See `ensurePlaceholderAccount`.
  private static func ensurePlaceholderCategory(database: Database, id: UUID) throws {
    let exists = try CategoryRow.filter(CategoryRow.Columns.id == id).fetchOne(database)
    guard exists == nil else { return }
    try CategoryRow(domain: Moolah.Category(id: id, name: "stub")).insert(database)
  }

  /// See `ensurePlaceholderAccount`.
  private static func ensurePlaceholderEarmark(
    database: Database, id: UUID, instrument: Instrument
  ) throws {
    let exists = try EarmarkRow.filter(EarmarkRow.Columns.id == id).fetchOne(database)
    guard exists == nil else { return }
    try EarmarkRow(domain: Earmark(id: id, name: "stub", instrument: instrument))
      .insert(database)
  }

  /// Seeds earmarks into the in-memory store.
  /// Note: Earmark saved/spent/balance are computed from transactions in the repositories,
  /// so you must also seed corresponding transactions for earmarks that need non-zero balances.
  @discardableResult
  static func seed(
    earmarks: [Earmark],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    writeOrTrap(database) { database in
      for earmark in earmarks {
        try EarmarkRow(domain: earmark).upsert(database)
      }
    }
    return earmarks
  }

  /// Seeds categories into the in-memory store.
  @discardableResult
  static func seed(
    categories: [Moolah.Category],
    in database: any DatabaseWriter
  ) -> [Moolah.Category] {
    writeOrTrap(database) { database in
      for category in categories {
        try CategoryRow(domain: category).upsert(database)
      }
    }
    return categories
  }

  /// Seeds investment values into the in-memory store. Auto-seeds a stub
  /// account row for any `accountId` the test didn't seed explicitly,
  /// matching the SwiftData-era seeding pattern.
  @discardableResult
  static func seed(
    investmentValues: [UUID: [InvestmentValue]],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [UUID: [InvestmentValue]] {
    writeOrTrap(database) { database in
      for (accountId, values) in investmentValues {
        try ensurePlaceholderAccount(
          database: database, id: accountId, instrument: instrument)
        for value in values {
          try InvestmentValueRow(domain: value, accountId: accountId).insert(database)
        }
      }
    }
    return investmentValues
  }

  /// Seeds earmark budget items into the in-memory store. Auto-seeds a
  /// stub earmark row keyed by `earmarkId` and stub category rows for
  /// every `item.categoryId` the test didn't seed explicitly.
  static func seedBudget(
    earmarkId: UUID,
    items: [EarmarkBudgetItem],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) {
    writeOrTrap(database) { database in
      try ensurePlaceholderEarmark(
        database: database, id: earmarkId, instrument: instrument)
      for item in items {
        try ensurePlaceholderCategory(database: database, id: item.categoryId)
        try EarmarkBudgetItemRow(domain: item, earmarkId: earmarkId).insert(database)
      }
    }
  }
}
