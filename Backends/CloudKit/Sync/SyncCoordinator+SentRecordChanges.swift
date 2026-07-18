@preconcurrency import CloudKit
import Foundation
import OSLog
import os

extension SyncCoordinator {
  enum MissingSentHandlerAction: Equatable {
    case recover
    case ignoreIntentionalTeardown
  }

  private struct MissingSentHandlerResults {
    let savedRecords: [CKRecord]
    let failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave]
    let failedDeletes: [(CKRecord.ID, CKError)]
  }

  @MainActor
  func missingSentHandlerAction(for profileId: UUID) -> MissingSentHandlerAction {
    intentionallyUnavailableDataHandlerIds.contains(profileId)
      ? .ignoreIntentionalTeardown : .recover
  }

  /// Processes sent-record acknowledgements on the cooperative pool. The
  /// handlers perform synchronous GRDB reads and writes, so this explicit
  /// `@concurrent` boundary makes off-actor execution explicit under both
  /// Swift 6.2 concurrency modes. Awaiting each zone preserves the delegate event's
  /// ordering; only coordinator state mutation hops back to `MainActor`.
  @concurrent
  func handleSentRecordZoneChangesAsync(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) async {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin,
      log: Signposts.sync,
      name: "handleSentChanges",
      signpostID: signpostID,
      "%{public}d saved %{public}d failedSaves %{public}d failedDeletes",
      sentChanges.savedRecords.count,
      sentChanges.failedRecordSaves.count,
      sentChanges.failedRecordDeletes.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.sync,
        name: "handleSentChanges",
        signpostID: signpostID)
    }
    Self.offActorLogger.info(
      "sentRecordZoneChanges: saved=\(sentChanges.savedRecords.count) failedSaves=\(sentChanges.failedRecordSaves.count) failedDeletes=\(sentChanges.failedRecordDeletes.count)"
    )

    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for record in sentChanges.savedRecords {
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }

    var failedSavesByZone:
      [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
        .FailedRecordSave]] = [:]
    for failure in sentChanges.failedRecordSaves {
      failedSavesByZone[failure.record.recordID.zoneID, default: []].append(failure)
    }

    var failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]] = [:]
    for (recordID, error) in sentChanges.failedRecordDeletes {
      failedDeletesByZone[recordID.zoneID, default: []].append((recordID, error))
    }

    let allZones = Set(savedByZone.keys)
      .union(failedSavesByZone.keys)
      .union(failedDeletesByZone.keys)

    for zoneID in allZones {
      await processSentZone(
        zoneID: zoneID,
        savedByZone: savedByZone,
        failedSavesByZone: failedSavesByZone,
        failedDeletesByZone: failedDeletesByZone)
    }

    await MainActor.run {
      updateQuotaExceededState(from: sentChanges)
    }
  }

  @concurrent
  private func processSentZone(
    zoneID: CKRecordZone.ID,
    savedByZone: [CKRecordZone.ID: [CKRecord]],
    failedSavesByZone: [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
      .FailedRecordSave]],
    failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]]
  ) async {
    precondition(
      !Thread.isMainThread,
      "Sent-record zone persistence must not run on the main thread")
    let zoneType = Self.parseZone(zoneID)
    let failures: SyncErrorRecovery.ClassifiedFailures

    switch zoneType {
    case .profileIndex:
      failures = profileIndexHandler.handleSentRecordZoneChanges(
        savedRecords: savedByZone[zoneID] ?? [],
        failedSaves: failedSavesByZone[zoneID] ?? [],
        failedDeletes: failedDeletesByZone[zoneID] ?? [])

    case .profileData(let profileId):
      // A sent result can only follow a batch built by this coordinator, so
      // the zone handler should already be cached. Do not create one here:
      // first-access construction opens/migrates its GRDB queue synchronously.
      let (handler, missingAction): (ProfileDataSyncHandler?, MissingSentHandlerAction) =
        await MainActor.run {
          (
            dataHandlers[profileId],
            missingSentHandlerAction(for: profileId)
          )
        }
      guard let handler else {
        await recoverMissingSentHandler(
          profileId: profileId,
          action: missingAction,
          zoneID: zoneID,
          results: MissingSentHandlerResults(
            savedRecords: savedByZone[zoneID] ?? [],
            failedSaves: failedSavesByZone[zoneID] ?? [],
            failedDeletes: failedDeletesByZone[zoneID] ?? []),
        )
        return
      }
      failures = await handler.handleSentRecordZoneChanges(
        savedRecords: savedByZone[zoneID] ?? [],
        failedSaves: failedSavesByZone[zoneID] ?? [],
        failedDeletes: failedDeletesByZone[zoneID] ?? [])

    case .unknown:
      Self.offActorLogger.warning("Sent changes for unknown zone: \(zoneID.zoneName)")
      return
    }

    await MainActor.run {
      processSentFailures(failures, zoneID: zoneID)
    }
  }

  @concurrent
  private func recoverMissingSentHandler(
    profileId: UUID,
    action: MissingSentHandlerAction,
    zoneID: CKRecordZone.ID,
    results: MissingSentHandlerResults
  ) async {
    if action == .ignoreIntentionalTeardown {
      Self.offActorLogger.info(
        "Ignoring delayed sent changes for intentionally unavailable profile \(profileId)"
      )
      return
    }
    Self.offActorLogger.error(
      "Missing cached handler for sent changes, profile \(profileId); re-queueing results"
    )
    let failures = SyncErrorRecovery.classify(
      failedSaves: results.failedSaves,
      failedDeletes: results.failedDeletes,
      logger: Self.offActorLogger)
    await MainActor.run {
      processSentFailures(
        failures,
        zoneID: zoneID,
        additionalSaves: results.savedRecords.map(\.recordID))
    }
  }

  @MainActor
  private func processSentFailures(
    _ failures: SyncErrorRecovery.ClassifiedFailures,
    zoneID: CKRecordZone.ID,
    additionalSaves: [CKRecord.ID] = []
  ) {
    let plan = SyncErrorRecovery.recoveryPlan(
      failures, additionalSaves: additionalSaves)
    if !plan.pendingChanges.isEmpty {
      syncEngine?.state.add(pendingRecordZoneChanges: plan.pendingChanges)
    }

    if !plan.zoneNotFoundSaves.isEmpty || !plan.zoneNotFoundDeletes.isEmpty {
      var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      pendingChanges += plan.zoneNotFoundSaves.map { .saveRecord($0) }
      pendingChanges += plan.zoneNotFoundDeletes.map { .deleteRecord($0) }
      ensureProfileZone(zoneID, pendingChanges: pendingChanges)
    }
  }

  @MainActor
  private func updateQuotaExceededState(
    from sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    let hasQuotaErrors = sentChanges.failedRecordSaves.contains { $0.error.code == .quotaExceeded }
    if hasQuotaErrors {
      applyQuotaState(true)
    } else if !sentChanges.failedRecordSaves.isEmpty || !sentChanges.savedRecords.isEmpty {
      applyQuotaState(false)
    }
    refreshPendingUploadsMirror()
  }
}
