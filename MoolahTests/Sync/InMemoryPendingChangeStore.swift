@preconcurrency import CloudKit

@testable import Moolah

/// In-memory ``PendingChangeStore`` double for driving `SyncCoordinator`'s
/// upload-batch builder without a live `CKSyncEngine` (whose `State` has no
/// constructible test instance). It stands in for `CKSyncEngine.State`'s pending
/// record-zone-change list.
///
/// ## Fidelity to `CKSyncEngine.State` — deliberately minimal
/// The drain pipeline depends on only two State behaviours, and this double
/// models exactly those, no more:
///
/// - **Insertion order is preserved** across `add`/`remove`. This is the
///   load-bearing property: `dedupedPendingChanges` walks `pendingRecordZoneChanges`
///   in order with first-occurrence dedup, then `prefix(400)` takes the head — so
///   "the same dead 400 at the head every cycle" only reproduces if order is
///   stable. A `Set`-backed or reordering double would stop modelling the wedge.
/// - **`remove` deletes every entry matching the given changes** (same type AND
///   recordID). The wedge-drain fix calls `state.remove(.saveRecord(staleID))`
///   explicitly to clear the head, so `remove` is what actually drains.
///
/// `add` appends, with **same-type dedup only** (adding a change already present
/// is a no-op — Apple documents the engine "deduplicat[es] as necessary"). It
/// does NOT model opposite-type supersede (adding `.deleteRecord(X)` does not
/// drop a pending `.saveRecord(X)`): the drain never exercises it — production
/// does an explicit `remove(.saveRecord)` *then* `add(.deleteRecord)`, never
/// `add(.deleteRecord)` over a live save — and a save+delete for one id can
/// genuinely coexist in flight (#1090). Encoding supersede would be unexercised,
/// contested fiction.
///
/// This double therefore proves the app's drain *pipeline* drains and stays
/// drained against a faithful ordered model of State; it does NOT prove real
/// `CKSyncEngine.State`'s add/remove/ordering (Apple-undocumented in full) — the
/// ground truth for that is the live migration, not this test.
@MainActor
final class InMemoryPendingChangeStore: PendingChangeStore {
  private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []

  init(_ initial: [CKSyncEngine.PendingRecordZoneChange] = []) {
    add(pendingRecordZoneChanges: initial)
  }

  func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    var present = Set(pendingRecordZoneChanges.map(Self.exactKey))
    for change in changes where present.insert(Self.exactKey(change)).inserted {
      pendingRecordZoneChanges.append(change)
    }
  }

  func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    let toRemove = Set(changes.map(Self.exactKey))
    pendingRecordZoneChanges.removeAll { toRemove.contains(Self.exactKey($0)) }
  }

  /// The record a change targets (nil only for a future, unknown case).
  static func recordID(
    of change: CKSyncEngine.PendingRecordZoneChange
  ) -> CKRecord.ID? {
    switch change {
    case .saveRecord(let id): return id
    case .deleteRecord(let id): return id
    @unknown default: return nil
    }
  }

  /// Exact identity (type + record) for dedup and remove-by-exact-change.
  static func exactKey(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
    switch change {
    case .saveRecord(let id): return "save\u{1}\(id.zoneID.zoneName)\u{1}\(id.recordName)"
    case .deleteRecord(let id): return "delete\u{1}\(id.zoneID.zoneName)\u{1}\(id.recordName)"
    @unknown default: return "unknown\u{1}\(String(describing: change))"
    }
  }
}
