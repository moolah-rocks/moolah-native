@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cross-device dispatch test for `WalletSyncCheckpointRecord`: drives
/// `ProfileDataSyncHandler.applyRemoteChanges` with a synthetic CKRecord
/// representing a checkpoint synced down from another device, then verifies
/// the local `wallet_sync_checkpoint` row carries the propagated block number.
/// Mirrors `InsightDismissalSyncIntegrationTests`' harness construction.
@Suite("WalletSyncCheckpoint sync integration")
struct WalletSyncCheckpointSyncIntegrationTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test
  func applyRemoteChangesPersistsCheckpoint() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }

    // The record another device would have uploaded: a checkpoint of block
    // 1000 for an account. The record name / id are keyed by the account id.
    let accountId = UUID()
    let checkpoint = WalletSyncCheckpoint(id: accountId, lastSyncedBlockNumber: 1000)
    let row = WalletSyncCheckpointRow(checkpoint: checkpoint)
    let recordID = CKRecord.ID(
      recordType: WalletSyncCheckpointRow.recordType, uuid: row.id, zoneID: Self.zoneID)
    let ckRecord = CKRecord(
      recordType: "WalletSyncCheckpointRecord", recordID: recordID)
    ckRecord["lastSyncedBlockNumber"] = Int64(1000) as CKRecordValue

    // Apply incoming save — must NOT throw, must NOT report .saveFailed.
    let saveResult = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = saveResult {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    // The receiving device's repository now reports the propagated checkpoint.
    let receiver = GRDBWalletSyncCheckpointRepository(database: harness.database)
    let loaded = try await receiver.load(accountId: accountId)
    #expect(loaded?.lastSyncedBlockNumber == 1000)
  }
}
