@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CKRecord user-field comparison")
struct CKRecordUserFieldComparisonTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("equal user fields compare equal; a differing field compares unequal")
  func sameUserFields() {
    let id = UUID()
    let a = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "X")
      .toCKRecord(in: Self.zoneID)
    let b = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "X")
      .toCKRecord(in: Self.zoneID)
    let c = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Y")
      .toCKRecord(in: Self.zoneID)
    #expect(a.hasSameUserFields(as: b))
    #expect(!a.hasSameUserFields(as: c))
  }
}
