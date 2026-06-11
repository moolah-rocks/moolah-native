@preconcurrency import CloudKit
import Foundation

// Start-time purge of stale pre-prefixing (issue #416) pending changes for
// `SyncCoordinator`. Called from `completeStart` in `+Lifecycle.swift`.
@MainActor
extension SyncCoordinator {
  /// Removes any pending change whose recordName is a bare UUID (no `|`
  /// separator and parses as a UUID). Such entries can only have been
  /// persisted by a build that predated the `<recordType>|<UUID>` prefix
  /// (issue #416). Post-prefix they collide with their prefixed counterparts
  /// during batch build — both pass the `Set<CKRecord.ID>` dedup (different
  /// recordNames) but resolve to the same UUID and the same local row,
  /// so the same `CKRecord` instance gets appended to `recordsToSave` twice
  /// and CloudKit rejects the entire batch with `.invalidArguments`
  /// ("You can't save the same record twice").
  ///
  /// Instrument records use raw string IDs (`"AUD"`, `"ASX:BHP"`) which
  /// don't parse as UUIDs, so they are correctly excluded by this check.
  func purgeStaleBareUUIDPendingChanges() {
    guard let syncEngine else { return }
    let stale = syncEngine.state.pendingRecordZoneChanges.filter { change in
      let recordName: String
      switch change {
      case .saveRecord(let id): recordName = id.recordName
      case .deleteRecord(let id): recordName = id.recordName
      @unknown default: return false
      }
      return !recordName.contains("|") && UUID(uuidString: recordName) != nil
    }
    guard !stale.isEmpty else { return }
    logger.warning(
      "Purging \(stale.count, privacy: .public) stale bare-UUID pending changes left over from pre-prefixing CKSyncEngine state"
    )
    syncEngine.state.remove(pendingRecordZoneChanges: stale)
  }
}
