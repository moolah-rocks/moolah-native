// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

@preconcurrency import CloudKit
import Foundation
import OSLog
import os

// Fetched-change application (off-main, hops to `@MainActor` for observer
// notifications) and sent-change handling (on-main, per-zone failure dispatch
// + quota tracking) for `SyncCoordinator`.
extension SyncCoordinator {

  // MARK: - Fetched Record Zone Changes

  /// Processes fetched record zone changes with heavy database work off the main actor.
  /// Resolves handlers and manages state on @MainActor; upsert/delete/save runs off-main.
  nonisolated func handleFetchedRecordZoneChangesAsync(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
  ) async {
    // Group records by zone off-main
    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for modification in changes.modifications {
      let record = modification.record
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }
    var deletedByZone: [CKRecordZone.ID: [(CKRecord.ID, String)]] = [:]
    for deletion in changes.deletions {
      deletedByZone[deletion.recordID.zoneID, default: []]
        .append((deletion.recordID, deletion.recordType))
    }

    // Pre-extract system fields off-main
    let preExtractedSystemFields: [(String, Data)] = changes.modifications
      .map { ($0.record.recordID.recordName, $0.record.encodedSystemFields) }

    // Hop to main to update SyncProgress with this batch's counts.
    // Settled state is tracked separately via endFetchingChanges.
    let modCount = changes.modifications.count
    let delCount = changes.deletions.count
    await MainActor.run {
      self.accumulateProgressCounts(modifications: modCount, deletions: delCount)
    }

    let allZones = Set(savedByZone.keys).union(deletedByZone.keys)
    for zoneID in allZones {
      let saved = savedByZone[zoneID] ?? []
      let deleted = deletedByZone[zoneID] ?? []
      await applyFetchedZoneChanges(
        zoneID: zoneID,
        saved: saved,
        deleted: deleted,
        preExtractedSystemFields: preExtractedSystemFields)
    }
  }

  /// Applies fetched changes for a single zone, wrapping the per-kind dispatch
  /// in a signpost and slow-zone log.
  nonisolated private func applyFetchedZoneChanges(
    zoneID: CKRecordZone.ID,
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)]
  ) async {
    let zoneType = Self.parseZone(zoneID)

    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID,
      "%{public}@ %{public}d saves %{public}d deletes", zoneID.zoneName, saved.count,
      deleted.count)
    let zoneStart = ContinuousClock.now

    switch zoneType {
    case .profileIndex:
      await applyFetchedIndexChanges(saved: saved, deleted: deleted)

    case .profileData(let profileId):
      await applyFetchedProfileDataChanges(
        profileId: profileId,
        zoneID: zoneID,
        saved: saved,
        deleted: deleted,
        preExtractedSystemFields: preExtractedSystemFields)

    case .unknown:
      logger.warning("Received changes for unknown zone: \(zoneID.zoneName)")
    }

    os_signpost(.end, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID)
    let zoneMs = (ContinuousClock.now - zoneStart).inMilliseconds
    if zoneMs > 100 {
      logger.info(
        "applyFetchedChanges took \(zoneMs)ms (\(zoneID.zoneName), \(saved.count) saves, \(deleted.count) deletes)"
      )
    }
  }

  /// Applies fetched changes for the profile-index zone. Off-main apply + MainActor
  /// hop for observer / refetch bookkeeping. Schedules a re-fetch on save failure.
  nonisolated private func applyFetchedIndexChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)]
  ) async {
    let deletedIDs = deleted.map(\.0)
    // Recovery tombstone shield (issue #1090 / #12) — suppress a re-delivered
    // deleted ProfileRecord so the token-less refetch can't resurrect an
    // empty-shell profile mid-recovery. See `applyFetchedProfileDataChanges`.
    let (toApply, suppressed) = await recoveryShieldedSaves(saved)
    if !suppressed.isEmpty {
      logger.warning(
        "Recovery shield suppressed \(suppressed.count, privacy: .public) re-delivered index deletion(s)"
      )
    }
    // Index upsert is fast (few records), run off-main. The single-device
    // echo race is guarded transactionally inside the handler's apply
    // write via the `needs_push` flag (issue #1081), so no main-actor
    // pre-snapshot is needed.
    let indexResult = profileIndexHandler.applyRemoteChanges(
      saved: toApply, deleted: deletedIDs)
    switch indexResult {
    case .success:
      await MainActor.run {
        // Successful apply proves local writes are working — reset the re-fetch
        // attempt counter so a future transient failure gets a full retry budget.
        resetRefetchAttempts()
        if isFetchingChanges {
          fetchSessionIndexChanged = true
        } else {
          notifyIndexObservers()
        }
      }
    case .saveFailed(let errorDescription):
      logger.error(
        "Profile index save failed, scheduling re-fetch: \(errorDescription, privacy: .public)")
      await scheduleRefetch()
    }
  }

  /// Applies fetched changes for a profile-data zone. Handler resolution runs on
  /// MainActor; the heavy upsert/delete/save runs off-main via a nonisolated
  /// handler method; observer notifications hop back to MainActor.
  nonisolated private func applyFetchedProfileDataChanges(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)]
  ) async {
    // Resolve handler on main (accesses @MainActor-isolated state).
    //
    // The catch-and-skip path covers genuinely transient errors from
    // `containerManager.database(for:)` (e.g. disk pressure or a
    // migration in flight). These are recoverable: CKSyncEngine
    // retries on the next launch and the records remain in iCloud.
    // No invariant violations can reach this point — the coordinator
    // constructs its own handler bundle, so `profileNotRegistered` is
    // unreachable on the apply path.
    //
    // The single-device echo race is guarded transactionally inside the
    // handler's apply write via the `needs_push` flag (issue #1081), so
    // no main-actor pending-record snapshot is taken here.
    let handler: ProfileDataSyncHandler? =
      await MainActor.run {
        do {
          return try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
        } catch {
          logger.error("Failed to get handler for profile \(profileId): \(error, privacy: .public)")
          return nil
        }
      }
    guard let handler else { return }

    // Recovery tombstone shield (issue #1090 / #12): during a bloated-state
    // recovery, the token-less full refetch re-delivers any record deleted
    // locally whose `.deleteRecord` never propagated. Drop those saves so the
    // replayed deletion wins on both the local row and the server — the per-repo
    // D1-b journal clear runs per-upserted-row, so suppressing the upsert also
    // skips the clear. `recoveryShieldedSaves` awaits the snapshot build, so
    // there is no race with the engine's automatic post-init fetch; it returns
    // everything unfiltered outside recovery.
    let (toApply, suppressed) = await recoveryShieldedSaves(saved)
    if !suppressed.isEmpty {
      logger.warning(
        "Recovery shield suppressed \(suppressed.count, privacy: .public) re-delivered deletion(s) for profile \(profileId, privacy: .public)"
      )
    }

    // Filter pre-extracted system fields to this zone (off-main)
    let savedNames = Set(toApply.map { $0.recordID.recordName })
    let zonePreExtracted = preExtractedSystemFields.filter { recordName, _ in
      savedNames.contains(recordName)
    }

    // Extract every non-nil `externalId` from the just-applied
    // `TransactionLegRecord` saves before handing off to the apply
    // path. The deduper hook below uses this set to scope its sweep to
    // legs the fetch could plausibly have introduced duplicates for —
    // bounded work even when an unrelated zone push arrived.
    let touchedExternalIds = Self.extractTouchedExternalIds(saved: toApply)

    // Heavy upsert/delete/save runs off-main via nonisolated method
    let result = handler.applyRemoteChanges(
      saved: toApply, deleted: deleted, preExtractedSystemFields: zonePreExtracted)

    switch result {
    case .success:
      await MainActor.run {
        // Successful apply proves local writes are working — reset the re-fetch
        // attempt counter so a future transient failure gets a full retry budget.
        resetRefetchAttempts()
      }
      // Run the cross-device leg deduper after the apply so any
      // duplicates introduced by a multi-device race collapse to one
      // canonical leg before subscribers see the post-fetch state.
      // Best-effort — failures are logged inside the deduper and
      // don't block downstream propagation. Stores observe their
      // repositories' GRDB `ValueObservation` streams directly, so
      // remote writes propagate without an explicit notification step.
      await runCrossDeviceLegDedup(
        profileId: profileId, touchedExternalIds: touchedExternalIds)
    case .saveFailed(let errorDescription):
      logger.error(
        "Profile data save failed for \(profileId), scheduling re-fetch: \(errorDescription, privacy: .public)"
      )
      await scheduleRefetch()
    }
  }

  // MARK: - Sent Record Zone Changes

  @MainActor
  func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID,
      "%{public}d saved %{public}d failedSaves %{public}d failedDeletes",
      sentChanges.savedRecords.count, sentChanges.failedRecordSaves.count,
      sentChanges.failedRecordDeletes.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID)
    }
    logger.info(
      "sentRecordZoneChanges: saved=\(sentChanges.savedRecords.count) failedSaves=\(sentChanges.failedRecordSaves.count) failedDeletes=\(sentChanges.failedRecordDeletes.count)"
    )

    // Group saved records by zone
    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for record in sentChanges.savedRecords {
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }

    // Group failed saves by zone
    var failedSavesByZone:
      [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
        .FailedRecordSave]] = [:]
    for failure in sentChanges.failedRecordSaves {
      failedSavesByZone[failure.record.recordID.zoneID, default: []].append(failure)
    }

    // Group failed deletes by zone
    var failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]] = [:]
    for (recordID, error) in sentChanges.failedRecordDeletes {
      failedDeletesByZone[recordID.zoneID, default: []].append((recordID, error))
    }

    // Process each zone's results through the appropriate handler
    let allZones = Set(savedByZone.keys)
      .union(failedSavesByZone.keys)
      .union(failedDeletesByZone.keys)

    for zoneID in allZones {
      processSentZone(
        zoneID: zoneID,
        savedByZone: savedByZone,
        failedSavesByZone: failedSavesByZone,
        failedDeletesByZone: failedDeletesByZone)
    }

    updateQuotaExceededState(from: sentChanges)
  }

  /// Runs one zone's sent-change results through the appropriate handler and
  /// handles any zone-not-found failures by creating the zone and re-queuing.
  @MainActor
  private func processSentZone(
    zoneID: CKRecordZone.ID,
    savedByZone: [CKRecordZone.ID: [CKRecord]],
    failedSavesByZone: [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
      .FailedRecordSave]],
    failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]]
  ) {
    let zoneType = Self.parseZone(zoneID)
    let failures: SyncErrorRecovery.ClassifiedFailures

    switch zoneType {
    case .profileIndex:
      failures = profileIndexHandler.handleSentRecordZoneChanges(
        savedRecords: savedByZone[zoneID] ?? [],
        failedSaves: failedSavesByZone[zoneID] ?? [],
        failedDeletes: failedDeletesByZone[zoneID] ?? [])

    case .profileData(let profileId):
      guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
      else {
        logger.error("Failed to get handler for sent changes, profile \(profileId)")
        return
      }
      failures = handler.handleSentRecordZoneChanges(
        savedRecords: savedByZone[zoneID] ?? [],
        failedSaves: failedSavesByZone[zoneID] ?? [],
        failedDeletes: failedDeletesByZone[zoneID] ?? [])

    case .unknown:
      logger.warning("Sent changes for unknown zone: \(zoneID.zoneName)")
      return
    }

    // Re-queue failures (except zone-not-found which needs zone creation)
    let (zoneNotFoundSaves, zoneNotFoundDeletes) = SyncErrorRecovery.requeueFailures(
      failures, syncEngine: syncEngine, logger: logger)

    // Handle zone-not-found: store records and create zone
    if !zoneNotFoundSaves.isEmpty || !zoneNotFoundDeletes.isEmpty {
      var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      pendingChanges += zoneNotFoundSaves.map { .saveRecord($0) }
      pendingChanges += zoneNotFoundDeletes.map { .deleteRecord($0) }
      ensureProfileZone(zoneID, pendingChanges: pendingChanges)
    }
  }

  /// Tracks whether the user's iCloud quota is exceeded across all zones in the
  /// current send cycle. Empty events (no saves, no failed saves) are ignored
  /// so the flag doesn't bounce to `false` on heartbeat send cycles.
  @MainActor
  private func updateQuotaExceededState(
    from sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    let hasQuotaErrors = sentChanges.failedRecordSaves.contains { $0.error.code == .quotaExceeded }
    if hasQuotaErrors {
      applyQuotaState(true)
    } else if !sentChanges.failedRecordSaves.isEmpty || !sentChanges.savedRecords.isEmpty {
      // Only clear if we actually processed records (not an empty event)
      applyQuotaState(false)
    }
    refreshPendingUploadsMirror()
  }

  /// Routes batch totals into `progress`. Internal so unit tests can drive
  /// the counter without constructing a `CKSyncEngine.Event` value.
  @MainActor
  func accumulateProgressCounts(modifications: Int, deletions: Int) {
    progress.recordReceived(modifications: modifications, deletions: deletions)
  }

  /// Single setter for the quota-exceeded flag and its `progress` mirror.
  /// Replaces direct writes to `isQuotaExceeded` from the send path.
  @MainActor
  func applyQuotaState(_ exceeded: Bool) {
    isQuotaExceeded = exceeded
    progress.setQuotaExceeded(exceeded)
  }

  /// Pushes the live `pendingRecordZoneChanges.count` into `progress`.
  /// Called after every send event and after queueing changes.
  ///
  /// No-ops when `syncEngine` is nil (engine not yet started, or running
  /// under `--ui-testing` where the coordinator is never started). Reading
  /// `?? 0` from a nil engine would falsely report zero pending uploads,
  /// collapsing any seed-set `pendingUploads` count and incorrectly
  /// triggering a settle to `.upToDate`.
  @MainActor
  func refreshPendingUploadsMirror() {
    guard let syncEngine else { return }
    progress.updatePendingUploads(syncEngine.state.pendingRecordZoneChanges.count)
  }

}
