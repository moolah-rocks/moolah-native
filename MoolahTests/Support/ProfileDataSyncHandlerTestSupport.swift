import CloudKit
import Foundation
import GRDB

@testable import Moolah

enum ProfileDataSyncHandlerTestSupport {
  /// Bundle of references the tests need to retain so the in-memory GRDB
  /// queue outlives the handler's use during the test.
  struct HandlerHarness {
    let handler: ProfileDataSyncHandler
    let database: DatabaseQueue
  }

  /// Builds a fresh `ProfileDataSyncHandler` plus the underlying GRDB
  /// queue it was wired to. Tests retain `database` so the in-memory
  /// queue outlives the handler's repository references.
  @MainActor
  static func makeHandlerWithDatabase(
    canonicalResolver: CanonicalInstrumentResolver? = nil
  ) throws -> HandlerHarness {
    try makeHandlerAndDatabase(canonicalResolver: canonicalResolver)
  }

  /// Same as `makeHandlerWithDatabase()` — a separate name for callers
  /// that distinguish "I only need the handler" from "I need to verify
  /// GRDB state".
  @MainActor
  static func makeHandlerAndDatabase(
    canonicalResolver: CanonicalInstrumentResolver? = nil
  ) throws -> HandlerHarness {
    let database = try ProfileDatabase.openInMemory()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let bundle = try Self.makeBundle(
      database: database, instrument: .defaultTestInstrument)
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      grdbRepositories: bundle,
      canonicalResolver: canonicalResolver)
    return HandlerHarness(handler: handler, database: database)
  }

  /// Test seed helper — opens a write transaction on `database` and
  /// invokes `seed` so callers can stamp the per-profile GRDB tables
  /// with whatever rows their test needs. A thin convenience over
  /// `try await database.write { database in seed(database) }`.
  @MainActor
  static func seed(
    into database: DatabaseQueue,
    _ seed: @Sendable (Database) throws -> Void
  ) async throws {
    try await database.write { database in
      try seed(database)
    }
  }

  // MARK: - Row builders
  //
  // Compact constructors for the most common per-record-type rows the
  // sync-handler tests seed. Each builder is a small fixture — name +
  // type/instrument, with sensible defaults for the audit columns.

  static func accountRow(
    id: UUID,
    name: String,
    type: String = "bank",
    instrumentId: String = Instrument.defaultTestInstrument.id,
    position: Int = 0,
    isHidden: Bool = false,
    encodedSystemFields: Data? = nil
  ) -> AccountRow {
    AccountRow(
      id: id,
      recordName: AccountRow.recordName(for: id),
      name: name,
      type: type,
      instrumentId: instrumentId,
      position: position,
      isHidden: isHidden,
      encodedSystemFields: encodedSystemFields,
      valuationMode: ValuationMode.recordedValue.rawValue)
  }

  static func transactionRow(
    id: UUID,
    date: Date = Date(),
    payee: String?,
    encodedSystemFields: Data? = nil
  ) -> TransactionRow {
    TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: date,
      payee: payee,
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
      encodedSystemFields: encodedSystemFields)
  }

  static func categoryRow(
    id: UUID,
    name: String,
    parentId: UUID? = nil,
    encodedSystemFields: Data? = nil
  ) -> CategoryRow {
    CategoryRow(
      id: id,
      recordName: CategoryRow.recordName(for: id),
      name: name,
      parentId: parentId,
      encodedSystemFields: encodedSystemFields)
  }

  static func instrumentRow(
    id: String = "AUD",
    kind: String = "fiatCurrency",
    name: String = "Australian Dollar",
    decimals: Int = 2,
    encodedSystemFields: Data? = nil
  ) -> InstrumentRow {
    InstrumentRow(
      id: id,
      recordName: InstrumentRow.recordName(for: id),
      kind: kind,
      name: name,
      decimals: decimals,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil,
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil,
      encodedSystemFields: encodedSystemFields)
  }

  static func earmarkRow(
    id: UUID,
    name: String,
    instrumentId: String = Instrument.defaultTestInstrument.id,
    position: Int = 0,
    isHidden: Bool = false,
    encodedSystemFields: Data? = nil
  ) -> EarmarkRow {
    EarmarkRow(
      id: id,
      recordName: EarmarkRow.recordName(for: id),
      name: name,
      position: position,
      isHidden: isHidden,
      instrumentId: instrumentId,
      savingsTarget: nil,
      savingsTargetInstrumentId: nil,
      savingsStartDate: nil,
      savingsEndDate: nil,
      encodedSystemFields: encodedSystemFields)
  }

  static func earmarkBudgetItemRow(
    id: UUID,
    earmarkId: UUID,
    categoryId: UUID,
    amount: Int64 = 0,
    instrumentId: String = Instrument.defaultTestInstrument.id,
    encodedSystemFields: Data? = nil
  ) -> EarmarkBudgetItemRow {
    EarmarkBudgetItemRow(
      id: id,
      recordName: EarmarkBudgetItemRow.recordName(for: id),
      earmarkId: earmarkId,
      categoryId: categoryId,
      amount: amount,
      instrumentId: instrumentId,
      encodedSystemFields: encodedSystemFields)
  }

  static func accountGroupRow(
    id: UUID,
    name: String,
    bucket: String = AccountBucket.current.rawValue,
    instrumentId: String = Instrument.defaultTestInstrument.id,
    position: Int = 0,
    encodedSystemFields: Data? = nil
  ) -> AccountGroupRow {
    AccountGroupRow(
      id: id,
      recordName: AccountGroupRow.recordName(for: id),
      name: name,
      bucket: bucket,
      instrumentId: instrumentId,
      position: position,
      encodedSystemFields: encodedSystemFields)
  }

  static func investmentValueRow(
    id: UUID,
    accountId: UUID,
    date: Date = Date(),
    value: Int64 = 0,
    instrumentId: String = Instrument.defaultTestInstrument.id,
    encodedSystemFields: Data? = nil
  ) -> InvestmentValueRow {
    InvestmentValueRow(
      id: id,
      recordName: InvestmentValueRow.recordName(for: id),
      accountId: accountId,
      date: date,
      value: value,
      instrumentId: instrumentId,
      encodedSystemFields: encodedSystemFields)
  }

  static func transactionLegRow(
    id: UUID,
    transactionId: UUID,
    accountId: UUID?,
    instrumentId: String = Instrument.defaultTestInstrument.id,
    quantity: Int64 = 0,
    type: String = "income",
    sortOrder: Int = 0,
    encodedSystemFields: Data? = nil
  ) -> TransactionLegRow {
    TransactionLegRow(
      id: id,
      recordName: TransactionLegRow.recordName(for: id),
      transactionId: transactionId,
      accountId: accountId,
      instrumentId: instrumentId,
      quantity: quantity,
      type: type,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: sortOrder,
      encodedSystemFields: encodedSystemFields)
  }

  /// Constructs a fully-populated `ProfileGRDBRepositories` bundle backed
  /// by the supplied `database`. All hooks are no-ops; tests that need
  /// to observe sync queueing should build their own bundle via the
  /// concrete repo constructors.
  static func makeBundle(
    database: any DatabaseWriter,
    instrument: Instrument
  ) throws -> ProfileGRDBRepositories {
    let conversionService = FakeConversionService.fixedRates([:])
    // Shared profile-index registry over its own in-memory DB —
    // mirrors production wiring; there is no per-profile `instrument`
    // table (dropped by `v10_drop_shared_instrument_legacy`).
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database),
      transferSuggestions: GRDBTransferSuggestionRepository(database: database),
      instruments: registry,
      categories: GRDBCategoryRepository(database: database),
      accounts: GRDBAccountRepository(
        database: database,
        instrumentResolver: registry,
        instrumentRegistrar: registry),
      accountGroups: GRDBAccountGroupRepository(database: database),
      insightDismissals: GRDBInsightDismissalRepository(database: database),
      earmarks: GRDBEarmarkRepository(
        database: database,
        defaultInstrument: instrument,
        instrumentResolver: registry),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database,
        defaultInstrument: instrument,
        instrumentResolver: registry),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: instrument,
        conversionService: conversionService,
        instrumentResolver: registry,
        instrumentRegistrar: registry),
      transactionLegs: GRDBTransactionLegRepository(database: database),
      database: database)
  }
}
