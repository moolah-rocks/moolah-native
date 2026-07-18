import CloudKit
import os

/// Shared error classification and recovery for CKSyncEngine send failures.
///
/// Classifies failed record saves and deletes into categories (conflicts,
/// zone-not-found, unknown items, etc.) and provides recovery helpers.
/// Used by `SyncCoordinator` to handle send failures across all zones.
enum SyncErrorRecovery {

  /// Categorized results from classifying failed record saves and deletes.
  struct ClassifiedFailures {
    /// Records that failed because the zone doesn't exist. Need zone creation + re-queue.
    var zoneNotFoundSaves: [CKRecord.ID] = []
    /// Deletes that failed because the zone doesn't exist.
    var zoneNotFoundDeletes: [CKRecord.ID] = []
    /// Conflict: server has a newer version. Caller should update system fields, then re-queue.
    var conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)] = []
    /// Record was deleted on server — caller should clear system fields, then re-queue.
    var unknownItems: [(recordID: CKRecord.ID, recordType: String)] = []
    /// Records that failed because the user's iCloud quota is exceeded.
    var quotaExceeded: [CKRecord.ID] = []
    /// All other re-queueable failures (limitExceeded, unexpected errors).
    var requeue: [CKRecord.ID] = []
    /// Failed deletes that should be re-queued (conflicts, limitExceeded, unexpected errors).
    /// CKSyncEngine drops failed deletes from its queue; re-queuing prevents permanent
    /// server-side orphans.
    var requeueDeletes: [CKRecord.ID] = []
  }

  struct RecoveryPlan {
    let pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
    let zoneNotFoundSaves: [CKRecord.ID]
    let zoneNotFoundDeletes: [CKRecord.ID]
  }

  /// Converts classified failures plus any successfully-sent records whose
  /// acknowledgement could not be persisted into a complete retry plan.
  static func recoveryPlan(
    _ failures: ClassifiedFailures,
    additionalSaves: [CKRecord.ID] = []
  ) -> RecoveryPlan {
    var pendingChanges = additionalSaves.map {
      CKSyncEngine.PendingRecordZoneChange.saveRecord($0)
    }
    pendingChanges += failures.conflicts.map { .saveRecord($0.recordID) }
    pendingChanges += failures.unknownItems.map { .saveRecord($0.recordID) }
    pendingChanges += failures.requeue.map { .saveRecord($0) }
    pendingChanges += failures.quotaExceeded.map { .saveRecord($0) }
    pendingChanges += failures.requeueDeletes.map { .deleteRecord($0) }
    return RecoveryPlan(
      pendingChanges: pendingChanges,
      zoneNotFoundSaves: failures.zoneNotFoundSaves,
      zoneNotFoundDeletes: failures.zoneNotFoundDeletes)
  }

  /// Classifies all failed saves and deletes from a sent-changes event.
  static func classify(
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)],
    logger: Logger
  ) -> ClassifiedFailures {
    var result = ClassifiedFailures()
    for failure in failedSaves {
      classifySaveFailure(failure, into: &result, logger: logger)
    }
    for (recordID, error) in failedDeletes {
      classifyDeleteFailure(recordID: recordID, error: error, into: &result, logger: logger)
    }
    return result
  }

  /// Route one failed save into the appropriate `ClassifiedFailures` bucket.
  private static func classifySaveFailure(
    _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
    into result: inout ClassifiedFailures,
    logger: Logger
  ) {
    let recordID = failure.record.recordID
    switch failure.error.code {
    case .zoneNotFound, .userDeletedZone:
      logger.warning(
        "Save failed (code=\(failure.error.code.rawValue, privacy: .public) zoneNotFound) for \(failure.record.recordType, privacy: .public) \(recordID.recordName) — queueing zone re-creation"
      )
      result.zoneNotFoundSaves.append(recordID)

    case .serverRecordChanged:
      if let serverRecord = failure.error.serverRecord {
        logger.info(
          "Save conflict (code=\(failure.error.code.rawValue, privacy: .public) serverRecordChanged) for \(failure.record.recordType, privacy: .public) \(recordID.recordName) — resolving"
        )
        result.conflicts.append((recordID: recordID, serverRecord: serverRecord))
      } else {
        // Server record unavailable — re-queue so the record isn't silently lost
        logger.warning(
          "serverRecordChanged with no serverRecord for \(failure.record.recordType, privacy: .public) \(recordID.recordName) — re-queuing"
        )
        result.requeue.append(recordID)
      }

    case .unknownItem:
      logger.info(
        "Save failed (code=\(failure.error.code.rawValue, privacy: .public) unknownItem) for \(failure.record.recordType, privacy: .public) \(recordID.recordName) — clearing system fields and re-queuing as insert"
      )
      result.unknownItems.append((recordID: recordID, recordType: failure.record.recordType))

    case .quotaExceeded:
      logger.error(
        "iCloud quota exceeded (code=\(failure.error.code.rawValue, privacy: .public)) — sync paused for \(failure.record.recordType, privacy: .public) \(recordID.recordName)"
      )
      result.quotaExceeded.append(recordID)

    case .limitExceeded, .batchRequestFailed:
      logger.warning(
        "Save deferred (code=\(failure.error.code.rawValue, privacy: .public)) for \(failure.record.recordType, privacy: .public) \(recordID.recordName) — re-queuing"
      )
      result.requeue.append(recordID)

    default:
      // Re-queue unexpected errors. CKSyncEngine handles transient errors
      // (network, rate limiting) automatically, but other errors drop the
      // record from the queue. Re-queuing ensures we don't silently lose data.
      logger.error(
        "Save error (code=\(failure.error.code.rawValue, privacy: .public)) for \(failure.record.recordType, privacy: .public) \(recordID.recordName): \(failure.error, privacy: .public) — re-queuing"
      )
      result.requeue.append(recordID)
    }
  }

  /// Route one failed delete into the appropriate `ClassifiedFailures` bucket.
  private static func classifyDeleteFailure(
    recordID: CKRecord.ID,
    error: CKError,
    into result: inout ClassifiedFailures,
    logger: Logger
  ) {
    switch error.code {
    case .zoneNotFound, .userDeletedZone:
      result.zoneNotFoundDeletes.append(recordID)

    case .unknownItem:
      // Record is already gone from the server — the delete has effectively
      // succeeded. Don't re-queue (would loop forever) and don't treat as a
      // failure. CKSyncEngine has already removed it from its pending queue.
      logger.info(
        "Delete returned unknownItem (code=\(error.code.rawValue, privacy: .public)) for \(recordID.recordName) — record already gone, treating as success"
      )

    default:
      // Re-queue any other delete failure (serverRecordChanged, limitExceeded,
      // unexpected errors). CKSyncEngine drops failed items from its queue, so
      // not re-queuing would leave the record on the server permanently.
      logger.error(
        "Delete error (code=\(error.code.rawValue, privacy: .public)) for \(recordID.recordName): \(error, privacy: .public) — re-queuing"
      )
      result.requeueDeletes.append(recordID)
    }
  }

}
