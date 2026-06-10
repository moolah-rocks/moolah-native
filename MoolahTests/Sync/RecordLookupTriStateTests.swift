@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tri-state record-lookup tests (issue #1087): the upload path must
/// distinguish a row that is genuinely absent (safe to drop the stale save +
/// queue a server deletion) from a lookup that FAILED (keep pending — never
/// delete a possibly-live record). These drive the real
/// `ProfileDataSyncHandler` lookups against an in-memory GRDB database,
/// forcing the `failed` case by dropping the queried table so the fetch
/// throws — proving the classification comes from the fetch wrappers
/// themselves, not from the caller guessing.
@Suite("record-lookup tri-state (issue #1087)")
@MainActor
struct RecordLookupTriStateTests {
  private func legRecordID(_ id: UUID, zone: CKRecordZone.ID) -> CKRecord.ID {
    CKRecord.ID(recordType: TransactionLegRow.recordType, uuid: id, zoneID: zone)
  }

  private func seedLeg(
    _ harness: ProfileDataSyncHandlerTestSupport.HandlerHarness, id: UUID
  ) async throws {
    try await ProfileDataSyncHandlerTestSupport.seed(into: harness.database) { database in
      try ProfileDataSyncHandlerTestSupport.transactionLegRow(
        id: id, transactionId: UUID(), accountId: nil, quantity: 1
      ).insert(database)
    }
  }

  /// Forces every subsequent leg fetch to throw by dropping the table.
  private func dropLegTable(
    _ harness: ProfileDataSyncHandlerTestSupport.HandlerHarness
  ) async throws {
    try await harness.database.write { database in
      try database.execute(sql: "DROP TABLE transaction_leg")
    }
  }

  // MARK: - Single-record path (recordToSave)

  @Test("recordToSave → .found for a present row")
  func recordToSaveFound() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    try await seedLeg(harness, id: id)
    let outcome = harness.handler.recordToSave(
      for: legRecordID(id, zone: harness.handler.zoneID))
    guard case .found = outcome else {
      Issue.record("expected .found")
      return
    }
  }

  @Test("recordToSave → .absent for a missing row (query succeeded)")
  func recordToSaveAbsent() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let outcome = harness.handler.recordToSave(
      for: legRecordID(UUID(), zone: harness.handler.zoneID))
    guard case .absent = outcome else {
      Issue.record("expected .absent")
      return
    }
  }

  @Test("recordToSave → .failed when the GRDB fetch throws")
  func recordToSaveFailed() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    try await dropLegTable(harness)
    let outcome = harness.handler.recordToSave(
      for: legRecordID(UUID(), zone: harness.handler.zoneID))
    guard case .failed = outcome else {
      Issue.record("expected .failed")
      return
    }
  }

  @Test("recordToSave → .failed for a record type this build does not handle")
  func recordToSaveFailedForUnknownType() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    // A prefixed recordID naming a type the dispatch doesn't handle must keep
    // the change pending (never delete a record of a type a newer build
    // introduced), not be treated as absent.
    let unknown = CKRecord.ID(
      recordType: "FutureUnknownRecord", uuid: UUID(), zoneID: harness.handler.zoneID)
    guard case .failed = harness.handler.recordToSave(for: unknown) else {
      Issue.record("expected .failed for an unhandled record type")
      return
    }
  }

  // MARK: - Batch path (buildBatchRecordLookup)

  @Test("buildBatchRecordLookup → .succeeded with a hit for a present row")
  func batchSucceededWithHit() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    try await seedLeg(harness, id: id)
    let outcome = harness.handler.buildBatchRecordLookup(
      byRecordType: [TransactionLegRow.recordType: [id]])
    guard case .succeeded(let hits) = outcome[TransactionLegRow.recordType] else {
      Issue.record("expected .succeeded")
      return
    }
    #expect(hits[id] != nil)
  }

  @Test("buildBatchRecordLookup → .succeeded with no hit for a missing row")
  func batchSucceededAbsent() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let outcome = harness.handler.buildBatchRecordLookup(
      byRecordType: [TransactionLegRow.recordType: [id]])
    guard case .succeeded(let hits) = outcome[TransactionLegRow.recordType] else {
      Issue.record("expected .succeeded")
      return
    }
    #expect(hits[id] == nil)
  }

  @Test("buildBatchRecordLookup → .failed for the whole group when the fetch throws")
  func batchFailedWhenFetchThrows() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    try await dropLegTable(harness)
    let id = UUID()
    let outcome = harness.handler.buildBatchRecordLookup(
      byRecordType: [TransactionLegRow.recordType: [id]])
    guard case .failed = outcome[TransactionLegRow.recordType] else {
      Issue.record("expected .failed")
      return
    }
  }
}
