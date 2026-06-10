import CloudKit
import Foundation

// `queueSave` / `queueDeletion` overloads for `SyncCoordinator`. Each
// appends a `pendingRecordZoneChange` to the engine's state and refreshes
// the sidebar mirror so the pending-uploads counter stays in sync.
extension SyncCoordinator {

  // MARK: - Pending Changes

  // During the short window between `start()` returning and `completeStart`
  // installing the engine, these queue calls silently no-op. That's safe
  // because no user-driven edits can reach `queueSave`/`queueDeletion` before
  // the UI is ready, and any already-persisted records are re-queued by
  // `queueAllExistingRecordsForAllZones` / `queueUnsyncedRecordsForAllProfiles`
  // inside `completeStart`.
  func queueSave(recordType: String, id: UUID, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(
      recordType: recordType, uuid: id, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  func queueSave(recordName: String, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  func queueDeletion(recordType: String, id: UUID, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(
      recordType: recordType, uuid: id, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  func queueDeletion(recordName: String, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    refreshPendingUploadsMirror()
  }

  /// Subset of `candidates` whose record IDs are NOT already queued for
  /// deletion in `pendingChanges`. Builds a `Set<CKRecord.ID>` from the
  /// pending `.deleteRecord` entries once (O(pending)) and then filters
  /// `candidates` against it (O(candidates)) — linear, so a deleted profile
  /// that left tens of thousands of stale uploads drains without a
  /// per-record scan on the main thread.
  ///
  /// Only `.deleteRecord` entries are consulted, so the same record-name is
  /// not queued for deletion twice. `.saveRecord` entries are not checked:
  /// the caller (`handleMissingRecordsToSave`) has already removed the
  /// candidate's stale save before calling this.
  nonisolated static func newMissingDeleteIDs(
    among candidates: [CKRecord.ID],
    pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
  ) -> [CKRecord.ID] {
    guard !candidates.isEmpty else { return [] }
    var pendingDeleteIds: Set<CKRecord.ID> = []
    pendingDeleteIds.reserveCapacity(pendingChanges.count)
    for change in pendingChanges {
      if case .deleteRecord(let id) = change {
        pendingDeleteIds.insert(id)
      }
    }
    if pendingDeleteIds.isEmpty { return candidates }
    return candidates.filter { !pendingDeleteIds.contains($0) }
  }

  /// Partitions per-id upload lookups into the records to upload and the
  /// genuinely-absent ids to drop + delete. `.found` → upload; `.absent`
  /// (query succeeded, row gone) → remove the stale save and queue a server
  /// deletion; `.failed` (GRDB threw / unhandled type / no registry) →
  /// omitted entirely so the change stays pending and retries (issue #1087).
  /// Pure and `nonisolated static` so the send-path classification is
  /// unit-testable without a live `CKSyncEngine`.
  nonisolated static func classifyLookups(
    _ entries: [(recordID: CKRecord.ID, outcome: RecordLookupOutcome)]
  ) -> (toSave: [CKRecord], absent: [CKRecord.ID]) {
    var toSave: [CKRecord] = []
    var absent: [CKRecord.ID] = []
    for entry in entries {
      switch entry.outcome {
      case .found(let record): toSave.append(record)
      case .absent: absent.append(entry.recordID)
      case .failed: break
      }
    }
    return (toSave, absent)
  }

  /// The subset of `changes` whose record lives in `zoneID`. Used by the
  /// profile-delete purge to drop every pending change for a deleted
  /// profile's data zone in one pass (issue #1087). Pure + `nonisolated
  /// static` so the zone match is unit-testable without a live engine.
  nonisolated static func pendingChanges(
    _ changes: [CKSyncEngine.PendingRecordZoneChange], inZone zoneID: CKRecordZone.ID
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    changes.filter { change in
      switch change {
      case .saveRecord(let id): return id.zoneID == zoneID
      case .deleteRecord(let id): return id.zoneID == zoneID
      @unknown default: return false
      }
    }
  }
}
