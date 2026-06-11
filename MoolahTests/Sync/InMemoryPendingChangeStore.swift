@preconcurrency import CloudKit

@testable import Moolah

/// In-memory ``PendingChangeStore`` double for driving `SyncCoordinator`'s
/// upload-batch builder without a live `CKSyncEngine` (which has no
/// constructible test instance). It stands in for `CKSyncEngine.State`'s pending
/// record-zone-change list.
///
/// ## Fidelity to real `CKSyncEngine.State`
/// The drain test trusts this double to behave like Apple's state, so the two
/// mutating operations mirror the documented contract from
/// `CloudKit.framework/Headers/CKSyncEngineState.h`:
///
/// - `addPendingRecordZoneChanges:` — "maintains a consistent collection of
///   tracked pending changes, **deduplicating them as necessary**", and the
///   *latest* change for a record wins: a `.saveRecord(X)` then `.deleteRecord(X)`
///   keeps only the delete; a `.deleteRecord(X)` then `.saveRecord(X)` keeps only
///   the save. Modelled here as: adding a change drops any existing change with
///   the same `recordID`, then appends the new one (supersede + dedup in one
///   rule).
/// - `removePendingRecordZoneChanges:` — "Removes the specified record zone
///   changes from the state." Modelled as removing entries that match the given
///   changes *exactly* (same type AND recordID) — removing a `.saveRecord(X)`
///   does not touch a pending `.deleteRecord(X)`.
///
/// These properties are pinned by `InMemoryPendingChangeStoreTests`. The one
/// detail Apple leaves unspecified is the array *position* of a superseded entry;
/// we append at the end. The drain assertions depend on the multiset of pending
/// changes and on drain-to-empty, not on exact ordering, so this is safe.
@MainActor
final class InMemoryPendingChangeStore: PendingChangeStore {
  private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []

  init(_ initial: [CKSyncEngine.PendingRecordZoneChange] = []) {
    add(pendingRecordZoneChanges: initial)
  }

  func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
    for change in changes {
      // Supersede + dedup: the latest change for a recordID is the one kept.
      if let id = Self.recordID(of: change) {
        pendingRecordZoneChanges.removeAll { Self.recordID(of: $0) == id }
      }
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

  /// Exact identity (type + record) for remove-by-exact-change matching.
  static func exactKey(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
    switch change {
    case .saveRecord(let id): return "save\u{1}\(id.zoneID.zoneName)\u{1}\(id.recordName)"
    case .deleteRecord(let id): return "delete\u{1}\(id.zoneID.zoneName)\u{1}\(id.recordName)"
    @unknown default: return "unknown\u{1}\(String(describing: change))"
    }
  }
}
