// Backends/GRDB/Sync/CategoryRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - CategoryRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift`. The
// CloudKit wire `recordType` ("CategoryRecord") is a frozen contract —
// existing iCloud zones reference this exact string — so it stays
// unchanged regardless of the local Swift type's name.

extension CategoryRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    CategoryRecordCloudKitFields(
      isTaxReportable: isTaxReportable ? 1 : 0,
      name: name,
      parentId: parentId?.uuidString,
      taxOwnerIdsEncoded: taxOwnerIdsEncoded
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CategoryRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = CategoryRecordCloudKitFields(from: ckRecord)
    return CategoryRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      parentId: fields.parentId.flatMap(UUID.init(uuidString:)),
      isTaxReportable: (fields.isTaxReportable ?? 0) != 0,
      taxOwnerIdsEncoded: fields.taxOwnerIdsEncoded,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
