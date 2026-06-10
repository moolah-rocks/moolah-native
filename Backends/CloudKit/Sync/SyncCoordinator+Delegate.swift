// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

@preconcurrency import CloudKit
import Foundation
import OSLog
import os

// `CKSyncEngineDelegate` conformance for `SyncCoordinator`. The delegate runs
// on CKSyncEngine's internal executor; both entry points hop to `@MainActor`
// for all state access.
extension SyncCoordinator: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    if case .fetchedRecordZoneChanges(let changes) = event {
      await handleFetchedRecordZoneChangesAsync(changes)
    } else if case .accountChange(let accountChange) = event {
      // Account-change handling now performs an `await` (GRDB read of
      // every profile id) so it can't be hosted inside a synchronous
      // `MainActor.run`. Hop directly to the main actor's async path.
      await handleAccountChangeOnMain(accountChange)
    } else {
      await MainActor.run {
        handleEventOnMain(event)
      }
    }
  }

  @MainActor
  private func handleAccountChangeOnMain(
    _ accountChange: CKSyncEngine.Event.AccountChange
  ) async {
    await handleAccountChange(accountChange)
  }

  @MainActor
  private func handleEventOnMain(_ event: CKSyncEngine.Event) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange:
      // Routed through `handleAccountChangeOnMain` in `handleEvent`
      // because the sign-out path performs an async GRDB read.
      break

    case .fetchedDatabaseChanges(let changes):
      handleFetchedDatabaseChanges(changes)

    case .fetchedRecordZoneChanges:
      // Handled by handleFetchedRecordZoneChangesAsync
      break

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .willFetchChanges:
      beginFetchingChanges()

    case .didFetchChanges:
      endFetchingChanges()

    case .didFetchRecordZoneChanges(let event):
      // Fires even when the fetch returned zero changes, so the
      // "Checking iCloud…" → "No profiles in iCloud yet." transition
      // is possible for first-run users with an empty index zone.
      markZoneFetched(event.zoneID)

    case .sentDatabaseChanges, .willFetchRecordZoneChanges,
      .willSendChanges, .didSendChanges:
      break

    @unknown default:
      logger.debug("Unknown sync engine event")
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      nextRecordZoneChangeBatchOnMain(context, syncEngine: syncEngine)
    }
  }

  @MainActor
  private func nextRecordZoneChangeBatchOnMain(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
    }

    let rawPendingCount = syncEngine.state.pendingRecordZoneChanges.count
    let pendingChanges = dedupedPendingChanges(
      syncEngine: syncEngine, scope: context.options.scope)
    guard !pendingChanges.isEmpty else {
      logBatchFilteredOut(rawPending: rawPendingCount, deduped: 0, reason: "dedup/zone-creation")
      return nil
    }
    guard let batchKind = Self.selectBatchKind(from: pendingChanges) else {
      logBatchFilteredOut(
        rawPending: rawPendingCount, deduped: pendingChanges.count,
        reason: "no recognised zone kind")
      return nil
    }
    let batch = Array(
      Self.filterChanges(pendingChanges, matching: batchKind).prefix(400))
    let (savesByZone, deletesByBatch) = partitionBatch(batch)
    let recordsToSave = buildRecordsToSave(savesByZone: savesByZone)
    let expectedSaves = savesByZone.values.reduce(0) { $0 + $1.count }
    logBatchOutcome(
      BatchOutcome(
        rawPending: rawPendingCount, deduped: pendingChanges.count,
        kind: batchKind, batch: batch.count, built: recordsToSave.count,
        expected: expectedSaves, deletes: deletesByBatch.count))
    guard !recordsToSave.isEmpty || !deletesByBatch.isEmpty else { return nil }
    return CKSyncEngine.RecordZoneChangeBatch(
      recordsToSave: recordsToSave,
      recordIDsToDelete: deletesByBatch,
      atomicByZone: batchKind.atomicByZone
    )
  }

  /// Splits a batch of pending changes into per-zone save IDs and a flat list of
  /// delete IDs.
  @MainActor
  private func partitionBatch(
    _ batch: [CKSyncEngine.PendingRecordZoneChange]
  ) -> (savesByZone: [CKRecordZone.ID: [CKRecord.ID]], deletes: [CKRecord.ID]) {
    var savesByZone: [CKRecordZone.ID: [CKRecord.ID]] = [:]
    var deletes: [CKRecord.ID] = []
    for change in batch {
      switch change {
      case .saveRecord(let recordID):
        savesByZone[recordID.zoneID, default: []].append(recordID)
      case .deleteRecord(let recordID):
        deletes.append(recordID)
      @unknown default:
        break
      }
    }
    return (savesByZone, deletes)
  }

  /// Emits a warning when the pending queue was non-empty but everything got
  /// filtered out before a batch could be built — highlights scope / dedup /
  /// zone-creation filters that are silently dropping work.
  @MainActor
  private func logBatchFilteredOut(rawPending: Int, deduped: Int, reason: String) {
    guard rawPending > 0 else { return }
    logger.warning(
      "nextBatch: pending=\(rawPending) deduped=\(deduped) — all filtered (\(reason)); returning nil"
    )
  }

  /// Counters captured at the end of one `nextBatch` call, grouped for
  /// `logBatchOutcome`.
  struct BatchOutcome {
    let rawPending: Int
    let deduped: Int
    let kind: BatchKind
    let batch: Int
    let built: Int
    let expected: Int
    let deletes: Int
  }

  /// Emits the per-call batch summary (always at info) and escalates to error
  /// when the batch build collapsed expected saves to zero — that's the
  /// signature of a silent record-drop during CKRecord construction.
  @MainActor
  private func logBatchOutcome(_ outcome: BatchOutcome) {
    logger.info(
      "nextBatch: pending=\(outcome.rawPending) deduped=\(outcome.deduped) kind=\(String(describing: outcome.kind)) batch=\(outcome.batch) saves=\(outcome.built)/\(outcome.expected) deletes=\(outcome.deletes)"
    )
    if outcome.built == 0 && outcome.expected > 0 {
      logger.error(
        "nextBatch: expected \(outcome.expected) saves but built 0 records — records remain pending"
      )
    }
  }

  /// Returns pending changes filtered to the delegate's scope, deduplicated by
  /// record ID, with records in zones awaiting creation skipped (they'll be
  /// re-queued by `ensureProfileZone` once the zone exists). See
  /// SYNC_GUIDE Rule 12.
  @MainActor
  private func dedupedPendingChanges(
    syncEngine: CKSyncEngine,
    scope: CKSyncEngine.SendChangesOptions.Scope
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    var seenSaves = Set<CKRecord.ID>()
    var seenDeletes = Set<CKRecord.ID>()
    return syncEngine.state.pendingRecordZoneChanges
      .filter { scope.contains($0) }
      .filter { change in
        switch change {
        case .saveRecord(let id): return seenSaves.insert(id).inserted
        case .deleteRecord(let id): return seenDeletes.insert(id).inserted
        @unknown default: return true
        }
      }
      .filter { change in
        // Skip records whose zone is in pendingZoneCreation
        let zoneID: CKRecordZone.ID
        switch change {
        case .saveRecord(let id): zoneID = id.zoneID
        case .deleteRecord(let id): zoneID = id.zoneID
        @unknown default: return true
        }
        return pendingZoneCreation[zoneID] == nil
      }
  }

  /// Builds `CKRecord`s to save for each zone in the batch, dispatching on zone
  /// kind. Records that have been deleted locally before the batch was built are
  /// converted to server deletions via `handleMissingRecordToSave`.
  @MainActor
  private func buildRecordsToSave(
    savesByZone: [CKRecordZone.ID: [CKRecord.ID]]
  ) -> [CKRecord] {
    var recordsToSave: [CKRecord] = []
    for (zoneID, recordIDs) in savesByZone {
      let zoneType = Self.parseZone(zoneID)

      switch zoneType {
      case .profileIndex:
        appendProfileIndexRecords(recordIDs: recordIDs, into: &recordsToSave)

      case .profileData(let profileId):
        appendProfileDataRecords(
          profileId: profileId, zoneID: zoneID,
          recordIDs: recordIDs, into: &recordsToSave)

      case .unknown:
        logger.warning("Pending save for unknown zone: \(zoneID.zoneName)")
      }
    }
    return recordsToSave
  }

  /// Looks up each profile-index record by ID and either appends it to
  /// `recordsToSave` or collects it for a single batched server-deletion
  /// queue at the end (locally-deleted-before-batch path).
  @MainActor
  private func appendProfileIndexRecords(
    recordIDs: [CKRecord.ID],
    into recordsToSave: inout [CKRecord]
  ) {
    let entries = recordIDs.map { recordID in
      (recordID: recordID, outcome: profileIndexHandler.recordToSave(for: recordID))
    }
    let (toSave, absent) = Self.classifyLookups(entries)
    recordsToSave.append(contentsOf: toSave)
    handleMissingRecordsToSave(absent)
  }

  /// Looks up profile-data records using a batch UUID lookup (plus an
  /// individual lookup for string-keyed `InstrumentRecord`s), appending any
  /// hits to `recordsToSave` and converting misses to server deletions.
  @MainActor
  private func appendProfileDataRecords(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    recordIDs: [CKRecord.ID],
    into recordsToSave: inout [CKRecord]
  ) {
    let handler: ProfileDataSyncHandler
    do {
      handler = try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    } catch {
      // Handler build failed: return WITHOUT classifying any id, so every
      // record stays pending and nothing is removed or queued for deletion
      // (issue #1087 safety invariant — a transient handler failure must
      // never delete a live record). The next batch retries.
      logger.error(
        "Failed to build handler for profile \(profileId): \(error, privacy: .public) — \(recordIDs.count, privacy: .public) records remain pending for retry"
      )
      return
    }

    // Group prefixed UUID-based recordIDs by their recordType so the batch
    // lookup can dispatch to the correct SwiftData type per group. Records
    // without a type prefix (instruments and stale legacy bare-UUIDs that
    // weren't purged) go to the per-record path. Two record types that
    // share a UUID land in different groups, which is what prevents the
    // batch from emitting the same `CKRecord` twice (issue #416 follow-up).
    var byRecordType: [String: [(CKRecord.ID, UUID)]] = [:]
    var unprefixedIDs: [CKRecord.ID] = []
    for recordID in recordIDs {
      if let recordType = recordID.prefixedRecordType, let uuid = recordID.uuid {
        byRecordType[recordType, default: []].append((recordID, uuid))
      } else {
        unprefixedIDs.append(recordID)
      }
    }

    // One IN-predicate fetch per recordType; result is keyed by recordType
    // and then by UUID, so cross-type collisions are impossible.
    let groups = byRecordType.mapValues { Set($0.map(\.1)) }
    let batchOutcomes = handler.buildBatchRecordLookup(byRecordType: groups)

    // Expand the per-type batch outcomes (plus the per-record / instrument
    // string-keyed path) into per-id tri-state lookups (issue #1087). A
    // recordType group whose batch query FAILED keeps every id pending
    // (classified `failed`); only an id absent from a SUCCEEDED query is
    // removed + queued for deletion.
    var entries: [(recordID: CKRecord.ID, outcome: RecordLookupOutcome)] = []
    for (recordType, items) in byRecordType {
      switch batchOutcomes[recordType] ?? .failed {
      case .failed:
        for (recordID, _) in items { entries.append((recordID, .failed)) }
      case .succeeded(let hits):
        for (recordID, uuid) in items {
          entries.append((recordID, hits[uuid].map(RecordLookupOutcome.found) ?? .absent))
        }
      }
    }
    // String-keyed (InstrumentRecord) and any remaining unprefixed IDs go
    // through the single-record path which detects strings vs UUIDs.
    for recordID in unprefixedIDs {
      entries.append((recordID, handler.recordToSave(for: recordID)))
    }

    let (toSave, absent) = Self.classifyLookups(entries)
    recordsToSave.append(contentsOf: toSave)
    handleMissingRecordsToSave(absent)
  }

  /// Handles records that are confirmed GONE locally (the lookup query
  /// succeeded and the row was absent — never a failed lookup; see the
  /// `RecordLookupOutcome` tri-state, issue #1087):
  ///
  /// 1. **Remove the stale `.saveRecord`s.** Without this the dead saves stay
  ///    at the head of the queue and `nextRecordZoneChangeBatch` re-selects
  ///    the same un-buildable 400 every cycle (`built=0`), wedging all
  ///    uploads. Removing them lets the queue drain to the next buildable
  ///    batch.
  /// 2. **Queue a compensating server deletion** for each id not already
  ///    pending-delete, in one `state.add(_:)` call.
  ///
  /// `newMissingDeleteIDs` dedups against existing pending deletions with one
  /// set build + one filter pass (O(pending + candidates)) so a large stale
  /// queue drains without a per-record linear scan on the main thread.
  @MainActor
  private func handleMissingRecordsToSave(_ recordIDs: [CKRecord.ID]) {
    guard let syncEngine, !recordIDs.isEmpty else { return }
    // Drop the stale saves so the head of the queue clears.
    syncEngine.state.remove(
      pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
    let novel = Self.newMissingDeleteIDs(
      among: recordIDs,
      pendingChanges: syncEngine.state.pendingRecordZoneChanges)
    if !novel.isEmpty {
      logger.info(
        "\(novel.count, privacy: .public) record(s) deleted locally before batch — queueing server deletion"
      )
      syncEngine.state.add(
        pendingRecordZoneChanges: novel.map { .deleteRecord($0) })
    }
    refreshPendingUploadsMirror()
  }
}
