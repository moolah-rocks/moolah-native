@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins ``InMemoryPendingChangeStore`` to the `CKSyncEngine.State` contract it
/// stands in for. The drain test (`SyncCoordinatorUploadDrainTests`) is only as
/// trustworthy as this double's fidelity, so the State semantics it relies on
/// are asserted here as first-class properties rather than left implicit in the
/// drain loop.
///
/// Source of truth: Apple's `CloudKit.framework/Headers/CKSyncEngineState.h`
/// doc comments on `-addPendingRecordZoneChanges:` (dedup + latest-change-wins)
/// and `-removePendingRecordZoneChanges:` (removes the specified changes).
@Suite("InMemoryPendingChangeStore — CKSyncEngine.State fidelity")
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

  @Test("add(save X) then add(delete X) keeps only the delete (latest wins)")
  func saveThenDeleteKeepsOnlyDelete() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore()
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])
    store.add(pendingRecordZoneChanges: [.deleteRecord(target)])

    #expect(store.pendingRecordZoneChanges.count == 1)
    #expect(InMemoryPendingChangeStore.recordID(of: store.pendingRecordZoneChanges[0]) == target)
    #expect(Self.isDelete(store.pendingRecordZoneChanges[0]))
  }

  @Test("add(delete X) then add(save X) keeps only the save (latest wins)")
  func deleteThenSaveKeepsOnlySave() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore()
    store.add(pendingRecordZoneChanges: [.deleteRecord(target)])
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])

    #expect(store.pendingRecordZoneChanges.count == 1)
    #expect(!Self.isDelete(store.pendingRecordZoneChanges[0]))
  }

  @Test("adding the same change twice dedups to one entry")
  func duplicateAddDedups() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore()
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])
    store.add(pendingRecordZoneChanges: [.saveRecord(target)])

    #expect(store.pendingRecordZoneChanges.count == 1)
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

  @Test("init applies the same dedup/supersede rule as add")
  func initDedups() {
    let target = Self.recordID("X")
    let store = InMemoryPendingChangeStore([.saveRecord(target), .deleteRecord(target)])

    #expect(store.pendingRecordZoneChanges.count == 1)
    #expect(Self.isDelete(store.pendingRecordZoneChanges[0]))
  }
}
