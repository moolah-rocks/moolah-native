@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cross-device dispatch test for `InsightDismissalRecord`: drives
/// `ProfileDataSyncHandler.applyRemoteChanges` with a synthetic CKRecord
/// representing a dismissal tally synced down from another device, then
/// verifies the local GRDB state carries the propagated count. Mirrors
/// `AccountGroupSyncIntegrationTests`' harness construction.
@Suite("InsightDismissal sync integration")
struct InsightDismissalSyncIntegrationTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test
  func applyRemoteChangesPropagatesDismissalCount() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }

    // The record another device would have uploaded: a tally of 2 for
    // `.subscriptionPriceHike`. Its id is deterministic from the kind, so
    // both devices address the same record.
    let row = InsightDismissalRow(kind: .subscriptionPriceHike, count: 2)
    let recordID = CKRecord.ID(
      recordType: InsightDismissalRow.recordType, uuid: row.id, zoneID: Self.zoneID)
    let ckRecord = CKRecord(recordType: "InsightDismissalRecord", recordID: recordID)
    ckRecord["kind"] = row.kind as CKRecordValue
    ckRecord["count"] = Int64(row.count) as CKRecordValue

    // Apply incoming save — must NOT throw, must NOT report .saveFailed.
    let saveResult = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = saveResult {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    // The receiving device's repository now reports the propagated count.
    let receiver = GRDBInsightDismissalRepository(database: harness.database)
    let all = try await receiver.fetchAll()
    #expect(all.first { $0.kind == .subscriptionPriceHike }?.count == 2)
  }
}
