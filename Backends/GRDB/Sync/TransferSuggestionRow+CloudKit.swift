import CloudKit
import Foundation

// MARK: - TransferSuggestionRow + CloudKitRecordConvertible
//
// The wire `recordType` ("TransferSuggestionRecord") is the stable
// contract for this record, so it stays unchanged regardless of the
// local Swift type's name.

extension TransferSuggestionRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    TransferSuggestionRecordCloudKitFields(
      suggestedAt: suggestedAt,
      transactionIdA: transactionIdA.uuidString,
      transactionIdB: transactionIdB.uuidString
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransferSuggestionRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TransferSuggestionRecordCloudKitFields(from: ckRecord)
    guard
      let transactionIdA = fields.transactionIdA.flatMap(UUID.init(uuidString:)),
      let transactionIdB = fields.transactionIdB.flatMap(UUID.init(uuidString:))
    else { return nil }
    return TransferSuggestionRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      transactionIdA: transactionIdA,
      transactionIdB: transactionIdB,
      suggestedAt: fields.suggestedAt ?? Date(timeIntervalSince1970: 0),
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
