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
    let first = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "X")
      .toCKRecord(in: Self.zoneID)
    let second = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "X")
      .toCKRecord(in: Self.zoneID)
    let differing = ProfileDataSyncHandlerTestSupport.accountRow(id: id, name: "Y")
      .toCKRecord(in: Self.zoneID)
    #expect(first.hasSameUserFields(as: second))
    #expect(!first.hasSameUserFields(as: differing))
  }
}
