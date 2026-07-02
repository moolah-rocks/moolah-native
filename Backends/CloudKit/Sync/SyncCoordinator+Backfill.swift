@preconcurrency import CloudKit
import Foundation
import OSLog

// Bulk record queueing for `SyncCoordinator`: initial migration / first-launch
// queues, unsynced-record backfill scans, per-profile scan-completion flags,
// and test-only hooks that exercise the same bookkeeping paths without
// dispatching real CKSyncEngine events.
@MainActor
extension SyncCoordinator {

  // MARK: - Queue All Existing Records

  /// Ensures the given profile's zone exists on CloudKit, then queues every record in
  /// that profile's local GRDB store for upload. Called by `ExportCoordinator`
  /// after a file import, which writes records directly to the database and so
  /// bypasses the repository `onRecordChanged` hooks that normally feed the sync engine.
  ///
  /// The zone is created first so the initial send does not have to round-trip through
  /// `.zoneNotFound` and `pendingZoneCreation`.
  ///
  /// Returns the record IDs that were queued (empty if the profile has no records or
  /// its handler couldn't be resolved). The caller is responsible for invoking
  /// `sendChanges()` afterwards if an immediate upload is desired.
  @discardableResult
  func queueAllRecordsAfterImport(for profileId: UUID) async -> [CKRecord.ID] {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Only hit CloudKit when the coordinator is actually running; tests never start
    // the engine and should not make network calls for zone creation.
    if isRunning {
      await ensureZoneExists(zoneID)
    }

    guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) else {
      logger.error("Failed to get handler for post-import queueing, profile \(profileId)")
      return []
    }
    let recordIDs = handler.queueAllExistingRecords()
    if !recordIDs.isEmpty {
      syncEngine?.state.add(
        pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
      refreshPendingUploadsMirror()
      logger.info(
        "Queued \(recordIDs.count) records for upload after import, profile \(profileId)")
    }
    // Mark the profile as backfill-scanned: we've just queued every record, which is
    // a strict superset of what the startup backfill scan would do. Prevents the next
    // launch from re-scanning this profile's local store for nothing.
    markBackfillScanComplete(for: profileId)
    return recordIDs
  }

  /// Scans every known cloud profile for records that have never been successfully
  /// synced (i.e. `encodedSystemFields == nil`) and queues them for upload. Called on
  /// coordinator start so users whose profiles were migrated on a previous build — where
  /// migration did not queue imported records — still end up with their data uploaded
  /// on the next launch.
  ///
  /// Idempotent: records that already have system fields are skipped, and CKSyncEngine's
  /// pending list dedupes against any other queued changes.
  @discardableResult
  func queueUnsyncedRecordsForAllProfiles() async -> [CKRecord.ID] {
    var queued: [CKRecord.ID] = []
    var scannedProfiles = 0
    var skippedProfiles = 0
    let allProfiles = await containerManager.allProfileIds()
    for profileId in allProfiles {
      // Skip profiles whose backfill scan has already run — the only work left for
      // those is normal sync traffic. This keeps the startup scan O(1) on the happy
      // path: after the first run per profile we never touch its local store again.
      if hasCompletedBackfillScan(for: profileId) {
        skippedProfiles += 1
        continue
      }
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
      else {
        logger.error("Failed to get handler for backfill queueing, profile \(profileId)")
        continue
      }
      let recordIDs = handler.queueUnsyncedRecords()
      scannedProfiles += 1
      if !recordIDs.isEmpty {
        syncEngine?.state.add(
          pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        refreshPendingUploadsMirror()
        queued.append(contentsOf: recordIDs)
      }
      markBackfillScanComplete(for: profileId)
    }
    logger.info(
      """
      Backfill scan complete: \(allProfiles.count) profiles total, \
      \(scannedProfiles) scanned, \(skippedProfiles) skipped (already flagged), \
      \(queued.count) unsynced records queued for upload
      """)
    return queued
  }

  /// Re-queues shared `InstrumentRecord` rows whose
  /// `encoded_system_fields` is `NULL`. Closes the residual idempotency
  /// gap between "shared-registry GRDB write committed" and
  /// "CKSyncEngine state file persisted" — if the app crashes between
  /// those two events, the union-runner row still exists in the shared
  /// DB but no pending change ever queued. The next launch catches it
  /// here.
  ///
  /// Idempotent — CKSyncEngine dedupes against any pending changes
  /// already in flight, and successful uploads stamp
  /// `encoded_system_fields`, so subsequent scans skip the row.
  /// Cheap: O(rows in shared `instrument` table) — typically a few
  /// hundred.
  @discardableResult
  func queueUnsyncedSharedInstruments() -> [CKRecord.ID] {
    let recordIDs = profileIndexHandler.queueUnsyncedSharedInstrumentRecords()
    if !recordIDs.isEmpty {
      syncEngine?.state.add(
        pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
      refreshPendingUploadsMirror()
      logger.info(
        "Self-heal queued \(recordIDs.count) unsynced shared instrument(s)")
    }
    return recordIDs
  }

  func queueAllExistingRecordsForAllZones() async {
    // Queue profile-index records
    let indexRecordIDs = profileIndexHandler.queueAllExistingRecords()
    if !indexRecordIDs.isEmpty {
      syncEngine?.state.add(
        pendingRecordZoneChanges: indexRecordIDs.map { .saveRecord($0) })
      refreshPendingUploadsMirror()
    }

    // Queue per-profile records
    for profileId in await containerManager.allProfileIds() {
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      do {
        let handler = try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
        let recordIDs = handler.queueAllExistingRecords()
        if !recordIDs.isEmpty {
          syncEngine?.state.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
          refreshPendingUploadsMirror()
        }
      } catch {
        logger.error("Failed to queue records for profile \(profileId): \(error, privacy: .public)")
      }
      // This path queued every record for the profile, so there is nothing left for
      // the per-launch backfill scan to find.
      markBackfillScanComplete(for: profileId)
    }
  }

  // MARK: - Backfill Scan Flags

  func hasCompletedBackfillScan(for profileId: UUID) -> Bool {
    userDefaults.bool(forKey: backfillScanCompleteKey(for: profileId))
  }

  func markBackfillScanComplete(for profileId: UUID) {
    userDefaults.set(true, forKey: backfillScanCompleteKey(for: profileId))
  }

  /// Clears the backfill-scan flag for one profile — called whenever the profile's
  /// local data is destroyed or its system fields are reset (zone deletion,
  /// encrypted data reset), so the next scan re-examines it instead of skipping
  /// based on stale state.
  func clearBackfillScanFlag(for profileId: UUID) {
    userDefaults.removeObject(forKey: backfillScanCompleteKey(for: profileId))
  }

  /// Clears every backfill-scan flag. Called on sign-out/switch-accounts, where
  /// the set of valid profiles may change entirely before the next scan runs.
  func clearAllBackfillScanFlags() {
    let prefix = Self.backfillScanCompleteKeyPrefix + "."
    for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      userDefaults.removeObject(forKey: key)
    }
  }

  private func backfillScanCompleteKey(for profileId: UUID) -> String {
    "\(Self.backfillScanCompleteKeyPrefix).\(profileId.uuidString)"
  }

  // MARK: - Test Hooks

  /// Test-only: runs the same bookkeeping as a CloudKit `.signOut` account event, so
  /// unit tests can verify backfill-flag cleanup without a real CKSyncEngine.
  func handleSignOutForTesting() async {
    await deleteAllLocalData()
    deleteStateSerialization()
    clearAllBackfillScanFlags()
    isFetchingChanges = false
  }

  /// Test-only: runs the same bookkeeping as a `.deleted` zone deletion for the given
  /// zone, so unit tests can verify backfill-flag cleanup without dispatching a real
  /// sync event.
  func handleZoneDeletedForTesting(zoneID: CKRecordZone.ID) {
    handleZoneDeleted(zoneID, zoneType: Self.parseZone(zoneID))
  }

  /// Test-only: runs the same bookkeeping as an `.encryptedDataReset` zone deletion,
  /// so unit tests can verify backfill-flag cleanup without dispatching a real sync
  /// event.
  func handleEncryptedDataResetForTesting(zoneID: CKRecordZone.ID) {
    handleEncryptedDataReset(zoneID, zoneType: Self.parseZone(zoneID))
  }

  /// Test-only: constructs and runs the unified identity migration exactly as the
  /// lifecycle does, so the wiring and ordering can be asserted without dispatching
  /// a real `CKSyncEngine` start. Delegates to `runUnifiedIdentityMigration()`,
  /// which skips when `sharedInstrumentRegistry` is nil.
  func runUnifiedIdentityMigrationForTesting() async {
    await runUnifiedIdentityMigration()
  }
}
