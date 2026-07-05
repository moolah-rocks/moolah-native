// MoolahTests/Backends/CloudKit/RoundTripTests.swift

import CloudKit
import Foundation
import Testing

@testable import Moolah

/// CloudKit domain→CKRecord→domain round-trip invariants for synced
/// record types whose adapters are thin enough not to warrant a dedicated
/// suite of their own.
@Suite("CloudKit record round-trips")
struct RoundTripTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "test", ownerName: CKCurrentUserDefaultName)

  // MARK: - WalletSyncCheckpointRecord

  @Test("WalletSyncCheckpoint round-trips id and lastSyncedBlockNumber")
  func walletSyncCheckpointRoundTrips() throws {
    let checkpoint = WalletSyncCheckpoint(
      id: UUID(), lastSyncedBlockNumber: 21_000_000)
    let row = WalletSyncCheckpointRow(checkpoint: checkpoint)

    let restored = try #require(
      WalletSyncCheckpointRow.fieldValues(from: row.toCKRecord(in: Self.zoneID)))

    #expect(restored.id == checkpoint.id)
    #expect(restored.toDomain() == checkpoint)
    #expect(restored.toDomain().lastSyncedBlockNumber == 21_000_000)
  }

  @Test("WalletSyncCheckpoint toCKRecord encodes lastSyncedBlockNumber")
  func walletSyncCheckpointEncodesBlockNumber() {
    let row = WalletSyncCheckpointRow(
      checkpoint: WalletSyncCheckpoint(id: UUID(), lastSyncedBlockNumber: 42))
    let record = row.toCKRecord(in: Self.zoneID)
    #expect(record["lastSyncedBlockNumber"] as? Int64 == 42)
  }

  @Test("WalletSyncCheckpoint fieldValues returns nil for record ID without prefix")
  func walletSyncCheckpointFieldValuesReturnsNilForRecordIDWithoutPrefix() {
    // A bare-UUID recordName returns nil — `recordID.uuid` requires the
    // `<TYPE>|<UUID>` prefix.
    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID)
    let ckRecord = CKRecord(
      recordType: WalletSyncCheckpointRow.recordType, recordID: recordID)
    ckRecord["lastSyncedBlockNumber"] = Int64(21_000_000) as CKRecordValue

    let restored = WalletSyncCheckpointRow.fieldValues(from: ckRecord)
    #expect(restored == nil, "Bare-UUID recordName must be rejected — caller logs and skips")
  }

  @Test("WalletSyncCheckpoint missing lastSyncedBlockNumber falls back to 0")
  func walletSyncCheckpointMissingFieldFallsBack() throws {
    let recordID = CKRecord.ID(
      recordType: WalletSyncCheckpointRow.recordType, uuid: UUID(), zoneID: Self.zoneID)
    let ckRecord = CKRecord(
      recordType: WalletSyncCheckpointRow.recordType, recordID: recordID)
    // lastSyncedBlockNumber intentionally not set

    let restored = try #require(WalletSyncCheckpointRow.fieldValues(from: ckRecord))
    #expect(restored.lastSyncedBlockNumber == 0)
  }
}
