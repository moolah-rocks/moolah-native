@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins ``InMemoryPendingChangeStore`` to the two `CKSyncEngine.State`
/// behaviours the drain pipeline actually depends on — insertion-ordered
/// storage and exact-match `remove` — plus same-type dedup. The drain test
/// (`SyncCoordinatorUploadDrainTests`) is only as trustworthy as this double, so
/// these properties are asserted directly rather than left implicit in the drain
/// loop.
///
/// Deliberately NOT asserted: opposite-type supersede (adding `.deleteRecord(X)`
/// dropping a pending `.saveRecord(X)`). The drain never exercises it — production
/// removes the stale save explicitly before adding the delete — and an in-flight
/// save+delete for one id can coexist (#1090). Modelling it would be unexercised,
/// contested fiction; the test below pins the opposite — that they coexist.
@Suite("InMemoryPendingChangeStore — drain-relevant State fidelity")
@MainActor
struct InMemoryPendingChangeStoreTests {

  private static let zone = CKRecordZone.ID(
    zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)

  private static func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zone)
  }

  private static func isDelete(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
    if case .deleteRecord = change { return true }
    return false
  }

  private static func names(
    _ changes: [CKSyncEngine.PendingRecordZoneChange]
  ) -> [String] {
    changes.compactMap { InMemoryPendingChangeStore.recordID(of: $0)?.recordName }
  }

  @Test("add preserves insertion order")
  func addPreservesInsertionOrder() {
    let store = InMemoryPendingChangeStore()
    store.add(pendingRecordZoneChanges: [.saveRecord(Self.recordID("a"))])
    store.add(pendingRecordZoneChanges: [
      .saveRecord(Self.recordID("b")), .saveRecord(Self.recordID("c")),
    ])

    #expect(Self.names(store.pendingRecordZoneChanges) == ["a", "b", "c"])
  }

  @Test("remove preserves the order of the surviving entries")
  func removePreservesOrder() {
    let store = InMemoryPendingChangeStore(
      ["a", "b", "c", "d"].map { .saveRecord(Self.recordID($0)) })

    store.remove(pendingRecordZoneChanges: [.saveRecord(Self.recordID("b"))])

    #expect(Self.names(store.pendingRecordZoneChanges) == ["a", "c", "d"])
  }

  @Test("adding the same change twice dedups to one entry (same-type dedup)")
  func duplicateAddDedups() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore()
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])

    #expect(store.pendingRecordZoneChanges.count == 1)
  }

  @Test("a save and a delete for the same id COEXIST — no opposite-type supersede")
  func saveAndDeleteCoexist() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore()
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])
    store.add(pendingRecordZoneChanges: [.deleteRecord(target)])

    #expect(store.pendingRecordZoneChanges.count == 2)
    #expect(!Self.isDelete(store.pendingRecordZoneChanges[0]))  // save first
    #expect(Self.isDelete(store.pendingRecordZoneChanges[1]))  // delete second
  }

  @Test("remove matches the exact change type — removing a delete leaves a pending save")
  func removeMatchesExactType() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore([.saveRecord(target)])

    // A delete for the same id must NOT remove the pending save.
    store.remove(pendingRecordZoneChanges: [.deleteRecord(target)])
    #expect(store.pendingRecordZoneChanges.count == 1)
    #expect(!Self.isDelete(store.pendingRecordZoneChanges[0]))

    // The matching save does.
    store.remove(pendingRecordZoneChanges: [.saveRecord(target)])
    #expect(store.pendingRecordZoneChanges.isEmpty)
  }

  @Test("remove only affects the targeted records")
  func removeOnlyTargeted() {
    let first = Self.recordID("X")
    let second = Self.recordID("Y")
    let store = InMemoryPendingChangeStore([.saveRecord(first), .saveRecord(second)])

    store.remove(pendingRecordZoneChanges: [.saveRecord(first)])

    #expect(store.pendingRecordZoneChanges.count == 1)
    #expect(InMemoryPendingChangeStore.recordID(of: store.pendingRecordZoneChanges[0]) == second)
  }
}
