import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRow ↔ CKRecord retired valuation field")
struct AccountRowCloudKitFieldsTests {
  @Test("account round trip neither reads nor writes the retired field")
  func retiredFieldIsIgnored() throws {
    let id = UUID()
    let row = AccountRow(
      id: id, recordName: "AccountRecord|\(id.uuidString)", name: "Brokerage",
      type: "investment", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil)
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)

    let record = row.toCKRecord(in: zoneID)
    #expect(record["valuationMode"] == nil)
    record["valuationMode"] = "recordedValue" as CKRecordValue

    let decoded = try #require(AccountRow.fieldValues(from: record))
    #expect(decoded.id == id)
    #expect(decoded.name == "Brokerage")
    #expect(decoded.toCKRecord(in: zoneID)["valuationMode"] == nil)
  }
}
