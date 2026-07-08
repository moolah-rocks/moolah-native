// Backends/GRDB/Sync/TaxOwnerRow+CloudKit.swift

import CloudKit
import Foundation

extension TaxOwnerRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    TaxOwnerRecordCloudKitFields(
      kind: kind,
      name: name
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TaxOwnerRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TaxOwnerRecordCloudKitFields(from: ckRecord)
    return TaxOwnerRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      kind: fields.kind ?? TaxOwnerKind.individual.rawValue,
      encodedSystemFields: nil)
  }
}
