import CloudKit
import Foundation
import Testing

@testable import Moolah

/// CloudKit wire-format round-trip for `InsightDismissalRow`. Mirrors
/// `AccountGroupRowCKRecordTests` — lives in its own file so the Phase D
/// record type ships without edit-conflicting on the shared mapping suites.
@Suite("InsightDismissalRow CKRecord round-trip")
struct InsightDismissalRowCKRecordTests {

  private let zoneID = CKRecordZone.ID(
    zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  @Test
  func toCKRecordCarriesAllFields() throws {
    let row = InsightDismissalRow(kind: .subscriptionPriceHike, count: 4)

    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "InsightDismissalRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(InsightDismissalRow.recordType)|\(row.id.uuidString)")
    #expect(ckRecord["kind"] as? String == InsightKind.subscriptionPriceHike.rawValue)
    #expect((ckRecord["count"] as? Int64) == 4)
  }

  @Test
  func fieldValuesReconstructsRowFromCKRecord() throws {
    let id = UUID()
    let recordID = CKRecord.ID(
      recordType: InsightDismissalRow.recordType, uuid: id, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "InsightDismissalRecord", recordID: recordID)
    ckRecord["kind"] = InsightKind.feeSpend.rawValue as CKRecordValue
    ckRecord["count"] = Int64(7) as CKRecordValue

    let restored = try #require(InsightDismissalRow.fieldValues(from: ckRecord))
    #expect(restored.id == id)
    #expect(restored.kind == InsightKind.feeSpend.rawValue)
    #expect(restored.count == 7)
    // Stamped by applyGRDBBatchSave after upsert; never read from the
    // CKRecord itself.
    #expect(restored.encodedSystemFields == nil)
  }

  @Test
  func fieldValuesReturnsNilForRecordIDWithoutPrefix() {
    // A bare-UUID recordName returns nil — `recordID.uuid` requires the
    // `<TYPE>|<UUID>` prefix.
    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "InsightDismissalRecord", recordID: recordID)
    ckRecord["kind"] = InsightKind.feeSpend.rawValue as CKRecordValue
    ckRecord["count"] = Int64(1) as CKRecordValue

    let restored = InsightDismissalRow.fieldValues(from: ckRecord)
    #expect(restored == nil, "Bare-UUID recordName must be rejected — caller logs and skips")
  }

  @Test
  func roundTripsThroughCKRecord() throws {
    let row = InsightDismissalRow(kind: .subscriptionPriceHike, count: 4)

    let ckRecord = row.toCKRecord(in: zoneID)
    #expect(ckRecord.recordType == "InsightDismissalRecord")

    let decoded = try #require(InsightDismissalRow.fieldValues(from: ckRecord))
    #expect(decoded.id == row.id)
    #expect(decoded.kind == row.kind)
    #expect(decoded.count == 4)
  }
}
