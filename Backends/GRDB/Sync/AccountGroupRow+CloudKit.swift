import CloudKit
import Foundation

// MARK: - AccountGroupRow + CloudKitRecordConvertible
//
// The wire `recordType` ("AccountGroupRecord") is the stable contract
// for this record, so it stays unchanged regardless of the local Swift
// type's name.

extension AccountGroupRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    AccountGroupRecordCloudKitFields(
      bucket: bucket,
      instrumentId: instrumentId,
      name: name,
      position: Int64(position)
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountGroupRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = AccountGroupRecordCloudKitFields(from: ckRecord)
    return AccountGroupRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      // Unknown / missing bucket falls back to `.current`; the
      // `DataFormatVersion` gate guards against a future bucket case
      // reaching an older build. Mirrors `AccountGroupRow.toDomain`.
      bucket: fields.bucket ?? AccountBucket.current.rawValue,
      // Missing instrumentId falls back to AUD — consistent with the
      // AccountRow CloudKit decoder. Production never writes a record
      // without an instrument.
      instrumentId: fields.instrumentId ?? "AUD",
      position: Int(fields.position ?? 0),
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
