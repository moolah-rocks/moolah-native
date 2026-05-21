@preconcurrency import CloudKit
import Foundation

extension SyncCoordinator {

  // MARK: - Batch Kind

  /// Zone-kind bucket for a single `RecordZoneChangeBatch`.
  ///
  /// `nextRecordZoneChangeBatch` emits one bucket per call so `atomicByZone` can
  /// be set per-kind: profile-index records are independent (no cascade on conflict),
  /// while profile-data records within a zone must commit together.
  /// See issue #61.
  enum BatchKind: Equatable {
    case profileIndex
    case profileData

    var atomicByZone: Bool {
      switch self {
      case .profileIndex: return false
      case .profileData: return true
      }
    }
  }

  /// Picks the next batch kind to emit from a list of pending changes.
  /// Profile-index wins when both kinds are pending so index conflicts drain first.
  /// Returns `nil` if no changes belong to a known zone kind.
  nonisolated static func selectBatchKind(
    from changes: some Sequence<CKSyncEngine.PendingRecordZoneChange>
  ) -> BatchKind? {
    var sawData = false
    for change in changes {
      let zoneID: CKRecordZone.ID
      switch change {
      case .saveRecord(let id): zoneID = id.zoneID
      case .deleteRecord(let id): zoneID = id.zoneID
      @unknown default: continue
      }
      switch parseZone(zoneID) {
      case .profileIndex: return .profileIndex
      case .profileData: sawData = true
      case .unknown: continue
      }
    }
    return sawData ? .profileData : nil
  }

  /// Filters pending changes to those matching the given batch kind, preserving order.
  nonisolated static func filterChanges(
    _ changes: [CKSyncEngine.PendingRecordZoneChange],
    matching kind: BatchKind
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    changes.filter { change in
      let zoneID: CKRecordZone.ID
      switch change {
      case .saveRecord(let id): zoneID = id.zoneID
      case .deleteRecord(let id): zoneID = id.zoneID
      @unknown default: return false
      }
      switch (parseZone(zoneID), kind) {
      case (.profileIndex, .profileIndex): return true
      case (.profileData, .profileData): return true
      default: return false
      }
    }
  }

}
