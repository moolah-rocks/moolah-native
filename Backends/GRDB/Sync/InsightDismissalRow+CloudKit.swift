import CloudKit
import Foundation

// MARK: - InsightDismissalRow + CloudKitRecordConvertible
//
// The wire `recordType` ("InsightDismissalRecord") is the stable contract for
// this record, unchanged regardless of the local Swift type's name.

extension InsightDismissalRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InsightDismissalRecordCloudKitFields(
      count: Int64(count),
      kind: kind
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InsightDismissalRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = InsightDismissalRecordCloudKitFields(from: ckRecord)
    return InsightDismissalRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      // A record with no kind is malformed; "" projects to nil in toDomain and
      // is dropped downstream. Mirrors AccountGroupRow's defensive fallbacks.
      kind: fields.kind ?? "",
      count: Int(fields.count ?? 0),
      // Stamped by applyGRDBBatchSave after upsert; never read from the CKRecord.
      encodedSystemFields: nil
    )
  }
}
