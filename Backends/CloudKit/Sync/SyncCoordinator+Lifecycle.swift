@preconcurrency import CloudKit
import Foundation
import OSLog
import os

// MARK: - Re-Fetch Backoff Constants
//
// `nonisolated` so they sit outside the `@MainActor` extension below;
// short-retry / long-retry plumbing is consulted from the off-main
// fetched-changes path.

extension SyncCoordinator {
  /// Maximum number of consecutive re-fetch attempts before giving up on the short-retry
  /// chain and falling back to the long-retry timer. A persistent local-save failure
  /// (e.g. database corruption, disk full) would otherwise produce an infinite
  /// 5-second retry loop. See issue #77.
  nonisolated static let maxRefetchAttempts = 5

  /// Interval between last-resort periodic retries after the short-retry budget is
  /// exhausted. Long enough to avoid battery / quota impact on a persistently failing
  /// device, but short enough that a device that comes back online (disk freed, schema
  /// migrated by a later app update, transient corruption cleared) recovers without
  /// requiring an app restart. See issue #77.
  nonisolated static let longRetryInterval: Duration = .seconds(30 * 60)

  /// Returns the exponential backoff delay for the given 1-based attempt number,
  /// starting at 5 seconds and doubling each attempt. Returns `nil` when `attempt`
  /// exceeds `maxRefetchAttempts` — the caller should stop retrying at that point.
  nonisolated static func refetchBackoff(forAttempt attempt: Int) -> Duration? {
    guard attempt >= 1, attempt <= maxRefetchAttempts else { return nil }
    // 5s, 10s, 20s, 40s, 80s
    let seconds = 5 * (1 << (attempt - 1))
    return .seconds(seconds)
  }
}

// Lifecycle management (start/stop), engine-level send/fetch wrappers, and
// per-fetch-session change accumulation for `SyncCoordinator`.
@MainActor
extension SyncCoordinator {

  // MARK: - Lifecycle

  /// Spawns and tracks a launch task that waits for any pending
  /// profile-index migration and then invokes `start` (defaults to
  /// `self.start()` — production callers omit the parameter).
  /// Production wiring (see `MoolahApp.configureSyncCoordinator`)
  /// routes the launch-time migration `Task` through here so
  /// CKSyncEngine cannot deliver fetched profile-data zone changes
  /// before the local profile index is hydrated. Without the gate,
  /// the index reads `ProfileStore` performs at launch can return
  /// zero profiles, no `ProfileSession` gets constructed for the
  /// unknown profile id, and `handlerForProfileZone(profileId:zoneID:)`
  /// traps via `preconditionFailure`.
  ///
  /// The spawned task is stored on `launchTask` so `stop()` can
  /// cancel it if the coordinator is torn down before the migration
  /// finishes; the post-await guard skips the start invocation in
  /// that case. Calling this method again replaces (and cancels)
  /// any prior pending launch.
  ///
  /// The `start` closure is a test seam so the await ordering can be
  /// verified without invoking the real `start()`, which constructs
  /// a `CKSyncEngine` (unsafe in a test process — it requires the
  /// iCloud entitlement and leaks background work past test
  /// teardown). Tests await `launchTask?.value` to observe the
  /// closure firing.
  func startAfter(
    profileIndexMigration: Task<Void, Never>?,
    start: (@MainActor @Sendable () -> Void)? = nil
  ) {
    launchTask?.cancel()
    launchTask = Task { @MainActor [weak self] in
      await profileIndexMigration?.value
      guard !Task.isCancelled, let self else { return }
      (start ?? self.start)()
    }
  }

  func start() {
    guard !isRunning, startTask == nil else { return }

    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "coordinatorStart", signpostID: signpostID)

    // `CKSyncEngine.init(configuration:)` synchronously unarchives the
    // `stateSerialization` blob via `NSKeyedUnarchiver`, which blocks the
    // calling thread for many seconds when the pending-record-zone-changes
    // queue has grown large (issue #1087: a bloated 42.5 MB persisted state).
    // It must not run on the MainActor. `prepareEngine` is `nonisolated
    // async`, so calling it from this `@MainActor`-originating `Task` runs its
    // body — including `CKSyncEngine.init` — on the cooperative pool, never on
    // the main thread (SE-0338; verified empirically, issue #565). A plain
    // `Task` (not `Task.detached`) keeps caller priority / task-locals per
    // CONCURRENCY_GUIDE §8 while still getting init off-main. The
    // end-of-startup signpost + "Started" log fire in `completeStart` once the
    // engine object is back on the main actor.
    let stateURL = self.stateFileURL
    let delegate: any CKSyncEngineDelegate & Sendable = self
    // Recovery eligibility is MainActor state (entitlements, account, attempt
    // ceiling); capture it here and pass it into the off-main `prepareEngine`,
    // which owns the byte-size measurement (issue #1090 / #12).
    let allowRecovery = self.isRecoveryAllowed
    let forceRecovery = self.isRecoveryForced
    let bloatThreshold = Self.bloatRecoveryByteThreshold
    startTask = Task { [weak self] in
      let prepared = await Self.prepareEngine(
        stateFileURL: stateURL,
        delegate: delegate,
        allowRecovery: allowRecovery,
        forceRecovery: forceRecovery,
        bloatThreshold: bloatThreshold)
      // `stop()` cancels `startTask` — if that races with prepareEngine, drop
      // the prepared engine. `delegate` strongly captures `self`, so the
      // `guard let self` alone would still succeed after a stop.
      guard !Task.isCancelled, let self else { return }
      self.completeStart(prepared: prepared, signpostID: signpostID)
    }
  }

  // `prepareEngine` (off-actor engine construction + the #1090/#12 byte-size
  // gate) lives in `SyncCoordinator+BloatRecovery.swift`.

  /// Back-on-MainActor half of `start()`: installs the engine and kicks off
  /// zone setup. Separate from `start()` so the heavy init can run off-actor.
  private func completeStart(
    prepared: PreparedEngine, signpostID: OSSignpostID
  ) {
    defer {
      os_signpost(.end, log: Signposts.sync, name: "coordinatorStart", signpostID: signpostID)
      startTask = nil
    }

    // Handle the byte-size gate outcome (issue #1090 / #12) BEFORE installing the
    // engine, so a `.recovered` launch arms the tombstone shield before the
    // engine's automatic post-init fetch can deliver a re-fetched record.
    applyRecoveryOutcome(prepared.recoveryOutcome, wasForced: prepared.recoveryWasForced)

    syncEngine = prepared.engine
    isFirstLaunch = prepared.isFirstLaunch
    isRunning = true
    let containerID = CloudKitContainer.app.containerIdentifier ?? "<nil>"
    logger.info("Started unified sync coordinator")
    logger.info("Sync container: \(containerID, privacy: .public)")

    // Purge any pending changes whose recordName is a bare UUID — these are
    // stale entries persisted by CKSyncEngine before issue #416 added the
    // `<recordType>|<UUID>` prefix. Post-fix `recordID.uuid` returns nil for
    // them, which would loop forever in the `nextRecordZoneChangeBatch` /
    // `handleMissingRecordToSave` cycle. Removing them outright is safe
    // because every still-relevant record has been re-queued in prefixed form
    // by the repository mutation hooks (or will be by the unsynced backfill
    // below).
    purgeStaleBareUUIDPendingChanges()
    // Drop any leftover `InstrumentRecord` pending changes routed to a
    // per-profile zone. The only legitimate path for an instrument
    // write is the shared registry on the `profile-index` zone, and
    // `ProfileDataSyncHandler.recordToSave` traps in DEBUG when one
    // reaches the per-profile handler — left in the queue, a single
    // such entry crashes the process the next time CKSyncEngine asks
    // for the next batch. See
    // `SyncCoordinator+LegacyInstrumentDrain.swift`.
    purgeLegacyInstrumentPendingChanges()

    let shouldBackfillUnsynced = !isFirstLaunch
    let runFirstLaunchQueue = isFirstLaunch
    zoneSetupTask = Task {
      await self.runZoneSetup(
        runFirstLaunchQueue: runFirstLaunchQueue,
        shouldBackfillUnsynced: shouldBackfillUnsynced)
    }

    // Initial iCloud availability probe. Skip when entitlements are missing
    // (already set synchronously in init). On `couldNotDetermine` or thrown
    // error we stay `.unknown` and rely on the subsequent `.accountChange`
    // delegate event. Stored so `stop()` can cancel a probe still in flight.
    if isCloudKitAvailable && iCloudAvailability == .unknown {
      availabilityProbeTask = Task { [weak self] in
        do {
          let status = try await CloudKitContainer.app.accountStatus()
          guard !Task.isCancelled else { return }
          self?.applyICloudAvailability(Self.mapAccountStatus(status))
        } catch {
          self?.logger.info(
            "Initial accountStatus probe threw: \(error, privacy: .public) — staying .unknown"
          )
        }
      }
    }
  }

  /// The async body of `zoneSetupTask`: start-time reconciliation + deletion
  /// replay, eager zone creation, the unsynced backfill, then a send. Eagerly
  /// creates the profile-index zone and all known profile-data zones (reactive
  /// creation in `handleSentRecordZoneChanges` remains a fallback per SYNC_GUIDE
  /// Rule 3). `Task.isCancelled` is checked after the journal scan and before
  /// the send so a `stop()` mid-setup doesn't act on a torn-down engine.
  private func runZoneSetup(
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

  func stop() {
    launchTask?.cancel()
    launchTask = nil
    startTask?.cancel()
    startTask = nil
    zoneSetupTask?.cancel()
    zoneSetupTask = nil
    availabilityProbeTask?.cancel()
    availabilityProbeTask = nil
    recoverySnapshotTask?.cancel()
    recoverySnapshotTask = nil
    isRecoveryShieldActive = false
    recoveringDeletions = []
    recoveryFetchDidSettle = false
    recoveryShieldSuppressAll = false
    recoveryReplayDidRun = false
    fetchChangesTask?.cancel()
    fetchChangesTask = nil
    canonicalResolverObservationTask?.cancel()
    canonicalResolverObservationTask = nil
    cancelRefetchTasks()
    for (_, task) in zoneCreationTasks {
      task.cancel()
    }
    zoneCreationTasks.removeAll()
    syncEngine = nil
    isRunning = false
    isFetchingChanges = false
    isQuotaExceeded = false
    // Reset availability so a subsequent `start()` re-probes. When
    // entitlements are missing the init-time `.unavailable(.entitlementsMissing)`
    // remains correct — a rebuild of the coordinator would be needed to clear it.
    applyICloudAvailability(
      isCloudKitAvailable ? .unknown : .unavailable(reason: .entitlementsMissing)
    )
    profileIndexFetchedAtLeastOnce = false
    fetchSessionTouchedIndexZone = false
    // `dataHandlers` and `cachedGRDBRepositories` are intentionally
    // retained across `stop()` / `start()` cycles. Both reference the
    // same `containerManager`-owned `DatabaseQueue` instances, which
    // remain valid; rebuilding them would just churn allocations. They
    // are cleared only by `deleteAllLocalData` (sign-out / account
    // switch), where the queues themselves need to be rebuilt against
    // the post-reset on-disk state.
    logger.info("Stopped unified sync coordinator")
    progress.didStop()
  }

  // MARK: - Pending Changes

  var hasPendingChanges: Bool {
    syncEngine.map { !$0.state.pendingRecordZoneChanges.isEmpty } ?? false
  }

  // `purgeStaleBareUUIDPendingChanges()` (issue #416 cleanup) lives in
  // `SyncCoordinator+StalePendingPurge.swift`.

  // The four `queueSave` / `queueDeletion` overloads live in
  // `SyncCoordinator+QueueChanges.swift`.

  func sendChanges() async {
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.sendChanges()
    } catch {
      logger.error("Failed to send changes: \(error, privacy: .public)")
    }
    // Clear-on-confirm (issue #1090): retire the journal row of any
    // replayed deletion whose `.deleteRecord` left the queue during this send
    // (CloudKit's only success signal for a delete), so it does not re-replay.
    await clearConfirmedReplayedDeletions()
  }

  func fetchChanges() async {
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.fetchChanges()
    } catch {
      logger.error("Failed to fetch changes: \(error, privacy: .public)")
    }
  }

  // MARK: - Fetch Session

  func beginFetchingChanges() {
    if isFetchingChanges {
      // Prior session ended abnormally — flush any pending index notification.
      logger.warning("Prior fetch session ended abnormally — flushing accumulated changes")
      flushFetchSessionIndexChange()
    }
    isFetchingChanges = true
    fetchSessionIndexChanged = false
    fetchSessionTouchedIndexZone = false
    progress.beginReceiving()
  }

  /// Called from the delegate zone-fetch event path. If the zone ID is the
  /// profile-index zone, sets `fetchSessionTouchedIndexZone = true` so
  /// `endFetchingChanges()` can flip `profileIndexFetchedAtLeastOnce`
  /// once we've definitively heard back from iCloud (Task 7).
  ///
  /// Guarded on `isFetchingChanges` so a stray `.didFetchRecordZoneChanges`
  /// outside a `willFetchChanges` / `didFetchChanges` envelope (e.g. a
  /// recovery re-fetch after `.zoneNotFound`) doesn't land on a stale
  /// session — the flag would otherwise be cleared by the next
  /// `endFetchingChanges()` before Task 7's flip could observe it.
  func markZoneFetched(_ zoneID: CKRecordZone.ID) {
    guard isFetchingChanges else { return }
    if SyncCoordinator.parseZone(zoneID) == .profileIndex {
      fetchSessionTouchedIndexZone = true
    }
  }

  func endFetchingChanges() {
    isFetchingChanges = false
    logger.info(
      "Fetch session complete: indexChanged: \(self.fetchSessionIndexChanged)"
    )
    flushFetchSessionIndexChange()
    if fetchSessionTouchedIndexZone && !profileIndexFetchedAtLeastOnce {
      profileIndexFetchedAtLeastOnce = true
      logger.info("profileIndexFetchedAtLeastOnce flipped true")
    }
    fetchSessionTouchedIndexZone = false
    progress.endReceiving(now: Date())
    // A full fetch session has completed — the forced post-recovery refetch (if
    // any) has now delivered everything. Record that and try to release the
    // recovery shield (issue #1090 / #12): it must outlive the refetch, not just
    // the delete-send. `isFetchingChanges` is already false here.
    if isRecoveryShieldActive {
      recoveryFetchDidSettle = true
      releaseRecoveryShieldIfSettled()
    }
  }

  /// Fires the index-observer callbacks if the profile-index zone changed
  /// during the current fetch session, then resets the flag. Profile-data
  /// changes propagate to stores via GRDB `ValueObservation` streams in the
  /// repositories — there is no per-profile observer chain to flush here.
  private func flushFetchSessionIndexChange() {
    if fetchSessionIndexChanged {
      notifyIndexObservers()
    }
    fetchSessionIndexChanged = false
  }
}
