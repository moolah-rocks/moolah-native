@preconcurrency import CloudKit

@testable import Moolah

/// A ``PendingChangeStore`` whose `remove` is a no-op — it models the
/// **pre-#1087 wedge**, where stale saves were never dropped from the head of the
/// queue. Used by the drain test's fail-without-fix (RED) check: driving the real
/// pipeline against this store must NOT drain (the same un-buildable head is
/// re-selected every cycle), proving the engine-bound test would catch a
/// reintroduced wedge rather than passing vacuously.
@MainActor
final class NonRemovingPendingChangeStore: PendingChangeStore {
  private let backing = InMemoryPendingChangeStore()

  init(_ initial: [CKSyncEngine.PendingRecordZoneChange] = []) {
    backing.add(pendingRecordZoneChanges: initial)
  }

  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
    backing.pendingRecordZoneChanges
  }

  func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    backing.add(pendingRecordZoneChanges: changes)
  }

  /// Intentionally does nothing — the stale saves stay at the head (the wedge).
  func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {}
}
