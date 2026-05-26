import CloudKit
import Foundation
import Testing

@testable import Moolah

/// CloudKit wire-format round-trip for `AccountGroupRow`. Mirrors the
/// shape of the per-type cases in `RecordMappingTests`; lives in its own
/// file because Phase 3 / Phase 7 ship as separate PRs and keeping the
/// new round-trip in a sibling file avoids edit conflicts on the busy
/// `RecordMappingTests.swift` file.
@Suite("AccountGroupRow CKRecord round-trip")
struct AccountGroupRowCKRecordTests {

  private let zoneID = CKRecordZone.ID(
    zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  @Test
  func toCKRecordCarriesAllFields() throws {
    let id = UUID()
    let row = AccountGroupRow(
      id: id,
      recordName: AccountGroupRow.recordName(for: id),
      name: "Trust Fund Crypto",
      bucket: AccountBucket.investments.rawValue,
      instrumentId: "AUD",
      position: 3,
      encodedSystemFields: nil)

    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "AccountGroupRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(AccountGroupRow.recordType)|\(row.id.uuidString)")
    #expect(ckRecord["name"] as? String == "Trust Fund Crypto")
    #expect(ckRecord["bucket"] as? String == AccountBucket.investments.rawValue)
    #expect(ckRecord["instrumentId"] as? String == "AUD")
    #expect((ckRecord["position"] as? Int64) == 3)
  }

  @Test
  func fieldValuesReconstructsRowFromCKRecord() throws {
    let id = UUID()
    let recordID = CKRecord.ID(
      recordType: AccountGroupRow.recordType, uuid: id, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "Personal Crypto" as CKRecordValue
    ckRecord["bucket"] = AccountBucket.investments.rawValue as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue

    let restored = try #require(AccountGroupRow.fieldValues(from: ckRecord))
    #expect(restored.id == id)
    #expect(restored.name == "Personal Crypto")
    #expect(restored.bucket == AccountBucket.investments.rawValue)
    #expect(restored.instrumentId == "AUD")
    #expect(restored.position == 0)
    // Stamped by applyGRDBBatchSave after upsert; never read from the
    // CKRecord itself.
    #expect(restored.encodedSystemFields == nil)
  }

  @Test
  func fieldValuesReturnsNilForRecordIDWithoutPrefix() {
    // A bare-UUID recordName (pre-issue-#416) returns nil — `recordID.uuid`
    // requires the `<TYPE>|<UUID>` prefix.
    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "X" as CKRecordValue
    ckRecord["bucket"] = AccountBucket.current.rawValue as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue

    let restored = AccountGroupRow.fieldValues(from: ckRecord)
    #expect(restored == nil, "Bare-UUID recordName must be rejected — caller logs and skips")
  }

  @Test
  func fieldValuesDefaultsBucketWhenMissing() throws {
    // A CKRecord missing the `bucket` field falls back to `.current` —
    // matches `AccountGroupRow.toDomain`'s defensive default.
    let id = UUID()
    let recordID = CKRecord.ID(
      recordType: AccountGroupRow.recordType, uuid: id, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountGroupRecord", recordID: recordID)
    ckRecord["name"] = "No Bucket" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue

    let restored = try #require(AccountGroupRow.fieldValues(from: ckRecord))
    #expect(restored.bucket == AccountBucket.current.rawValue)
  }

  @Test
  func fullDomainCKRecordRoundTrip() throws {
    let original = AccountGroup(
      id: UUID(),
      name: "Joint Accounts",
      bucket: .current,
      instrument: .defaultTestInstrument,
      position: 7)
    let outboundRow = AccountGroupRow(domain: original)

    let ckRecord = outboundRow.toCKRecord(in: zoneID)
    let inboundRow = try #require(AccountGroupRow.fieldValues(from: ckRecord))
    let restored = inboundRow.toDomain()

    #expect(restored.id == original.id)
    #expect(restored.name == original.name)
    #expect(restored.bucket == original.bucket)
    #expect(restored.instrument == original.instrument)
    #expect(restored.position == original.position)
  }
}
