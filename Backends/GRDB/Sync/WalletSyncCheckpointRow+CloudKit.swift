// Backends/GRDB/Sync/WalletSyncCheckpointRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - WalletSyncCheckpointRow + CloudKitRecordConvertible
//
// The wire `recordType` ("WalletSyncCheckpointRecord") is the stable
// contract for this record, unchanged regardless of the local Swift type's
// name.

extension WalletSyncCheckpointRow: CloudKitRecordConvertible {
  /// Builds a *fresh* record with no cached change tag. Upload callers must go
  /// through `ProfileDataSyncHandler.buildCKRecord(from:encodedSystemFields:)`
  /// to merge this row's cached system fields — that is the change-tag contract
  /// CloudKit needs to avoid spurious server-record-changed conflicts.
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    WalletSyncCheckpointRecordCloudKitFields(
      lastSyncedBlockNumber: lastSyncedBlockNumber
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> WalletSyncCheckpointRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = WalletSyncCheckpointRecordCloudKitFields(from: ckRecord)
    return WalletSyncCheckpointRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      lastSyncedBlockNumber: fields.lastSyncedBlockNumber ?? 0,
      // Stamped by applyGRDBBatchSave after upsert; never read from the CKRecord.
      encodedSystemFields: nil)
  }
}
