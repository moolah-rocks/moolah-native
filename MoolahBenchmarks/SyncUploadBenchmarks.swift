@preconcurrency import CloudKit
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for the sync upload path — `buildBatchRecordLookup` record resolution.
///
/// These measure the cost of building the UUID -> CKRecord lookup table that drives
/// outbound CKSyncEngine saves, which is the hot path when uploading a large batch
/// of local changes to CloudKit.
final class SyncUploadBenchmarks: XCTestCase {

  nonisolated(unsafe) private static var _database: DatabaseQueue?
  nonisolated(unsafe) private static var _handler: ProfileDataSyncHandler?
  nonisolated(unsafe) private static var _transactionUUIDs400: Set<UUID> = []
  nonisolated(unsafe) private static var _acknowledgedRecords400: [CKRecord] = []

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
      taxOwners: result.backend.grdbTaxOwners,
      accounts: result.backend.grdbAccounts,
      accountGroups: result.backend.grdbAccountGroups,
      insightDismissals: result.backend.grdbInsightDismissals,
      walletSyncCheckpoints: result.backend.grdbWalletSyncCheckpoints,
      earmarks: result.backend.grdbEarmarks,
      earmarkBudgetItems: result.backend.grdbEarmarkBudgetItems,
      transactions: result.backend.grdbTransactions,
      transactionLegs: result.backend.grdbTransactionLegs,
      database: result.database)
    let handler = MainActor.assumeIsolated {
      ProfileDataSyncHandler(
        profileId: profileId, zoneID: zoneID,
        grdbRepositories: bundle)
    }
    _handler = handler
    let ids = expecting("benchmark fetch existing ids failed") {
      try result.database.read { database in
        try TransactionRow
          .limit(400)
          .fetchAll(database)
          .map(\.id)
      }
    }
    _transactionUUIDs400 = Set(ids)
    _acknowledgedRecords400 = expecting("benchmark fetch acknowledged records failed") {
      try result.database.read { database in
        try TransactionRow
          .filter(ids.contains(TransactionRow.Columns.id))
          .fetchAll(database)
          .map { $0.toCKRecord(in: zoneID) }
      }
    }
    // Warm the one-time first-ack state transition before measurement so all
    // measured iterations exercise identical persisted state.
    warmAcknowledgementState(handler: handler, records: _acknowledgedRecords400)
  }

  private static func warmAcknowledgementState(
    handler: ProfileDataSyncHandler, records: [CKRecord]
  ) {
    _ = awaitSyncExpecting {
      await handler.handleSentRecordZoneChanges(
        savedRecords: records, failedSaves: [], failedDeletes: [])
    }
  }

  override static func tearDown() {
    _handler = nil
    _database = nil
    _transactionUUIDs400 = []
    _acknowledgedRecords400 = []
    super.tearDown()
  }

  private var handler: ProfileDataSyncHandler {
    guard let handler = Self._handler else {
      fatalError("setUp must initialise _handler before tests run")
    }
    return handler
  }
  private var transactionUUIDs400: Set<UUID> { Self._transactionUUIDs400 }
  private var acknowledgedRecords400: [CKRecord] { Self._acknowledgedRecords400 }

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Benchmarks

  /// Measures `buildBatchRecordLookup` for 400 transaction UUIDs in an 18k dataset.
  ///
  /// Uses IN-predicate batch fetches (6 queries total) rather than per-UUID sequential
  /// lookups (up to 2400 queries). All 400 UUIDs are existing transactions so the
  /// first fetch resolves all of them and the remaining 5 type queries are skipped.
  func testBuildBatchRecordLookup_400transactions() {
    let handler = handler
    let uuids = transactionUUIDs400
    let groups: [String: Set<UUID>] = [TransactionRow.recordType: uuids]
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting { @MainActor in
        handler.buildBatchRecordLookup(byRecordType: groups)
      }
    }
  }

  /// Measures the full acknowledgement persistence path for a realistic
  /// CKSyncEngine batch. The production entry point is `@concurrent`; its
  /// off-main precondition turns an accidental MainActor regression into an
  /// immediate benchmark failure instead of a latent UI stall.
  func testHandleSentAcknowledgements_400transactions() {
    let handler = handler
    let records = acknowledgedRecords400
    measure(metrics: metrics, options: options) {
      _ = awaitSyncExpecting {
        await handler.handleSentRecordZoneChanges(
          savedRecords: records, failedSaves: [], failedDeletes: [])
      }
    }
  }
}
