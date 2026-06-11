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
    enqueueSave(CKRecord.ID(recordType: recordType, uuid: id, zoneID: zoneID))
  }

  func queueSave(recordName: String, zoneID: CKRecordZone.ID) {
    enqueueSave(CKRecord.ID(recordName: recordName, zoneID: zoneID))
  }

  /// Adds a `.saveRecord` to the live engine, no-op until the engine is
  /// installed (the documented start-window behaviour — anything persisted
  /// before then is re-queued by the start-time backfill).
  private func enqueueSave(_ recordID: CKRecord.ID) {
    guard let syncEngine else { return }
    applySave(recordID, to: syncEngine.state)
  }

  /// Shared core of the save path + the create-hook hardening (issue #1090):
  /// BEFORE adding the save, drop any pending `.deleteRecord` for the same id,
  /// and drop it from `replayedDeletionsInFlight`. A re-created (or undeleted)
  /// record must not be killed by a replayed/in-flight deletion that is still
  /// sitting in the queue — `add(.saveRecord)` does NOT supersede a coexisting
  /// `.deleteRecord`, so the removal is explicit. (The repo's create write
  /// already cleared the journal row in-transaction; this clears the in-memory
  /// pending side.)
  ///
  /// `state` is a seam so the hardening is unit-testable without a live engine.
  func applySave(_ recordID: CKRecord.ID, to state: any PendingChangeStore) {
    state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    replayedDeletionsInFlight.removeValue(forKey: recordID)
    state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
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
    for case .deleteRecord(let id) in pendingChanges {
      pendingDeleteIds.insert(id)
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
