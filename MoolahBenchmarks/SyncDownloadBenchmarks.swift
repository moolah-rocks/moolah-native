@preconcurrency import CloudKit
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for the sync download path — `applyRemoteChanges` inserts and deletions.
///
/// These measure the cost of applying remote CKRecord changes to the local GRDB store,
/// which is the hot path when syncing a large transaction history from another device.
final class SyncDownloadBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _database: DatabaseQueue?
  nonisolated(unsafe) private static var _handler: ProfileDataSyncHandler?
  nonisolated(unsafe) private static var _zoneID: CKRecordZone.ID?

  // `XCTestCase.setUp` is nonisolated, so this override cannot carry
  // `@MainActor`. `ProfileDataSyncHandler.init` is the only call here
  // that requires the main actor; XCTest runs class-level setUp on the
  // main thread, so `MainActor.assumeIsolated` is safe.
  override static func setUp() {
    super.setUp()
    let result = expecting("benchmark TestBackend.create failed") {
      try TestBackend.create()
    }
    _database = result.database
    BenchmarkFixtures.seed(scale: .twoX, in: result.database)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let bundle = ProfileGRDBRepositories(
      csvImportProfiles: result.backend.grdbCSVImportProfiles,
      importRules: result.backend.grdbImportRules,
      transferSuggestions: result.backend.grdbTransferSuggestions,
      instruments: result.backend.grdbInstruments,
      categories: result.backend.grdbCategories,
      accounts: result.backend.grdbAccounts,
      accountGroups: result.backend.grdbAccountGroups,
      insightDismissals: result.backend.grdbInsightDismissals,
      walletSyncCheckpoints: result.backend.grdbWalletSyncCheckpoints,
      earmarks: result.backend.grdbEarmarks,
      earmarkBudgetItems: result.backend.grdbEarmarkBudgetItems,
      investmentValues: result.backend.grdbInvestments,
      transactions: result.backend.grdbTransactions,
      transactionLegs: result.backend.grdbTransactionLegs,
      database: result.database)
    _handler = MainActor.assumeIsolated {
      ProfileDataSyncHandler(
        profileId: profileId, zoneID: zoneID,
        grdbRepositories: bundle)
    }
    _zoneID = zoneID
  }

  override static func tearDown() {
    _handler = nil
    _zoneID = nil
    _database = nil
    super.tearDown()
  }

  private var database: DatabaseQueue {
    guard let database = Self._database else {
      fatalError("setUp must initialise _database before tests run")
    }
    return database
  }
  private var handler: ProfileDataSyncHandler {
    guard let handler = Self._handler else {
      fatalError("setUp must initialise _handler before tests run")
    }
    return handler
  }
  private var zoneID: CKRecordZone.ID {
    guard let zoneID = Self._zoneID else {
      fatalError("setUp must initialise _zoneID before tests run")
    }
    return zoneID
  }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Helpers

  /// Builds a CKRecord for a new transaction with a fresh UUID.
  private func makeFreshTransactionCKRecord(index: Int) -> CKRecord {
    let id = UUID()
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: TransactionRow.recordType, recordID: recordID)
    record["date"] = Date() as CKRecordValue
    record["payee"] = "Sync Insert \(index)" as CKRecordValue
    return record
  }

  /// Builds a CKRecord for a transaction leg.
  private func makeFreshLegCKRecord(transactionId: UUID, index: Int) -> CKRecord {
    let instrument = Instrument.defaultTestInstrument
    let legId = UUID()
    let recordID = CKRecord.ID(recordName: legId.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: TransactionLegRow.recordType, recordID: recordID)
    record["transactionId"] = transactionId.uuidString as CKRecordValue
    record["accountId"] = BenchmarkFixtures.heavyAccountId.uuidString as CKRecordValue
    record["instrumentId"] = instrument.id as CKRecordValue
    record["quantity"] =
      InstrumentAmount(
        quantity: Decimal(-(index + 1)), instrument: instrument
      ).storageValue as CKRecordValue
    record["type"] = TransactionType.expense.rawValue as CKRecordValue
    record["sortOrder"] = 0 as CKRecordValue
    return record
  }

  // MARK: - Benchmarks

  /// Applies 400 new transaction CKRecords with legs (insert path) into a 37k dataset.
  func testApplyRemoteChanges_400inserts() {
    let handler = handler
    measure(metrics: metrics, options: options) {
      var records: [CKRecord] = []
      records.reserveCapacity(800)
      for i in 0..<400 {
        let txnRecord = makeFreshTransactionCKRecord(index: i)
        guard let txnId = UUID(uuidString: txnRecord.recordID.recordName) else {
          preconditionFailure(
            "Fresh transaction CKRecord has a non-UUID recordName: "
              + txnRecord.recordID.recordName)
        }
        let legRecord = makeFreshLegCKRecord(transactionId: txnId, index: i)
        records.append(txnRecord)
        records.append(legRecord)
      }
      awaitSyncExpecting { @MainActor in
        _ = handler.applyRemoteChanges(saved: records, deleted: [])
      }
    }
  }

  /// Applies 400 deletion events into a 37k dataset.
  ///
  /// Re-seeds 400 transaction rows into GRDB before each measured iteration so the
  /// deletions always find live records to remove.
  func testApplyRemoteChanges_400deletions() {
    let handler = handler
    let database = self.database
    let zone = zoneID

    let clockOptions = XCTMeasureOptions()
    clockOptions.iterationCount = 10
    clockOptions.invocationOptions = [.manuallyStart, .manuallyStop]

    measure(metrics: [XCTClockMetric()], options: clockOptions) {
      // --- Setup (excluded from measurement) ---
      let deletionTargets: [(CKRecord.ID, String)] = expecting("seed deletion targets") {
        try Self.seedDeletionTargets(into: database, zone: zone, count: 400)
      }

      // --- Measurement ---
      self.startMeasuring()
      awaitSyncExpecting { @MainActor in
        _ = handler.applyRemoteChanges(saved: [], deleted: deletionTargets)
      }
      self.stopMeasuring()
    }
  }

  /// Seeds `count` transaction rows in `database` and returns the matching
  /// `(CKRecord.ID, recordType)` tuples so the deletion-benchmark loop can
  /// hand them to `applyRemoteChanges`.
  private static func seedDeletionTargets(
    into database: DatabaseWriter, zone: CKRecordZone.ID, count: Int
  ) throws -> [(CKRecord.ID, String)] {
    try database.write { database in
      var targets: [(CKRecord.ID, String)] = []
      targets.reserveCapacity(count)
      for _ in 0..<count {
        let id = UUID()
        let row = TransactionRow(
          id: id,
          recordName: TransactionRow.recordName(for: id),
          date: Date(),
          payee: "Delete Target",
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
        try row.insert(database)
        let ckRecordID = CKRecord.ID(recordName: id.uuidString, zoneID: zone)
        targets.append((ckRecordID, TransactionRow.recordType))
      }
      return targets
    }
  }
}
