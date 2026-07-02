@preconcurrency import CloudKit
import Foundation

// Zone-setup lifecycle for SyncCoordinator: one-shot start-time work —
// deletion replay, identity migration + alias cleanup, backfill queueing.
@MainActor
extension SyncCoordinator {

  // MARK: - Zone Setup

  /// The async body of `zoneSetupTask`: start-time reconciliation + deletion
  /// replay, eager zone creation, the unsynced backfill, then a send. Eagerly
  /// creates the profile-index zone and all known profile-data zones (reactive
  /// creation in `handleSentRecordZoneChanges` remains a fallback per SYNC_GUIDE
  /// Rule 3). `Task.isCancelled` is checked after the journal scan and before
  /// the send so a `stop()` mid-setup doesn't act on a torn-down engine.
  func runZoneSetup(
    runFirstLaunchQueue: Bool, shouldBackfillUnsynced: Bool
  ) async {
    // Start-time reconciliation (issue #1091): purge pending orphaned by a
    // profile deleted before the engine existed — see
    // `reconcilePendingAgainstLiveProfiles()`. It fetches its OWN live set via
    // the throwing path — must NOT use `allProfileIds()` below (which swallows
    // errors to `[]`).
    await reconcilePendingAgainstLiveProfiles()

    // Durable deletion-journal replay (issue #1090): re-issue every journaled
    // deletion as a `.deleteRecord` so a deletion survives an engine-down
    // window or a sync-state reset. Runs after reconciliation (issue #1091) —
    // the two act on disjoint zones (reconcile purges dead-profile DATA pending;
    // replay re-issues index `ProfileRecord` + live-profile data deletions), so
    // the order is conflict-free. See `SyncCoordinator+DeletionReplay`.
    await replayDeletionJournal()
    guard !Task.isCancelled else { return }
    await runUnifiedIdentityMigration()  // Before backfill; see method doc.
    guard !Task.isCancelled else { return }
    await runUnifiedIdentityAliasCleanup()  // After identity migration; before backfill.
    guard !Task.isCancelled else { return }
    // The alias cleanup writes new deletion_journal entries after the first
    // replayDeletionJournal() ran, so re-run now so its tombstones enqueue as
    // .deleteRecord this launch (idempotent — no-op when the journal is empty
    // on later launches after the cleanup has already completed).
    await replayDeletionJournal()
    guard !Task.isCancelled else { return }
    // On first launch (migration or truly first launch), queue all existing records.
    if runFirstLaunchQueue {
      await queueAllExistingRecordsForAllZones()
    }
    let profileIds = await containerManager.allProfileIds()
    await ensureZoneExists(profileIndexHandler.zoneID)
    for profileId in profileIds {
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      await ensureZoneExists(zoneID)
    }
    // After zones are confirmed, backfill any records that never got queued for
    // upload (e.g. data imported by migration on a build that predated the
    // migration→sync fix, or a previous run that crashed between the local write
    // and the sync-engine queue). Skipped on first launch because
    // `queueAllExistingRecordsForAllZones` has already queued everything.
    if shouldBackfillUnsynced {
      _ = await queueUnsyncedRecordsForAllProfiles()
    }
    // Shared-registry self-heal — re-queues any `instrument` row in the
    // profile-index DB whose `encoded_system_fields` is NULL. Closes the gap
    // between "union runner committed" and "engine state file persisted" by
    // catching first-launch rows that never made it into the pending list.
    // Cheap and idempotent. (The decommissioned per-profile-zone instrument
    // backfill is gone: every instrument upload routes through the shared
    // registry to the profile-index zone, and the DEBUG trap in
    // `ProfileDataSyncHandler.recordToSave` refuses any residual per-profile
    // `InstrumentRecord` upload.)
    _ = queueUnsyncedSharedInstruments()
    guard !Task.isCancelled else { return }
    if hasPendingChanges {
      logger.info("Zones ready — sending pending changes")
      await sendChanges()
    }
  }
}
