@preconcurrency import CloudKit
import Foundation
import OSLog

/// Stateless batch processing logic for the profile-index zone.
/// Contains all data transformation, upsert, deletion, and record-building
/// logic with no CKSyncEngine dependency.
///
/// The coordinator owns the CKSyncEngine instance and delegates data processing
/// to this handler. Methods return results (record IDs, failures) instead of
/// directly interacting with CKSyncEngine state.
///
/// Backed by `GRDBProfileIndexRepository`. Profile data is read and
/// written through the `ProfileRow` GRDB type; the CloudKit wire
/// `recordType` ("ProfileRecord") is a frozen contract that existing
/// iCloud zones reference verbatim.
///
/// **Dispatch by record type.** The handler dispatches by
/// `recordType` so that the profile-index zone can carry both
/// `ProfileRow` and `InstrumentRow` records (the latter from the
/// shared instrument registry). When an `instrumentRepository` is
/// supplied, instrument-shaped records are applied / built /
/// system-field-managed via the dispatched paths; when nil, every
/// instrument-shaped recordID is silently ignored (callers that don't
/// wire the registry to this zone, e.g. some test fixtures).
///
/// **Concurrency.** Nonisolated and `Sendable`. Every synchronous method
/// calls into the repository's `*Sync(...)` helpers which block the
/// calling thread on the GRDB queue. Declaring this `@MainActor` would
/// force every caller to block the UI thread. Callers must invoke these
/// methods away from `MainActor`; actor-isolated call sites expose an awaited
/// `@concurrent` async boundary and perform the synchronous handler work
/// within it, as the sent-acknowledgement coordinator path does.
/// All stored properties are themselves `Sendable` (`CKRecordZone.ID`,
/// `GRDBProfileIndexRepository`, optional `GRDBInstrumentRegistryRepository`,
/// `Logger`, `@Sendable` closure), so the conformance holds without
/// `@unchecked`.
final class ProfileIndexSyncHandler: Sendable {
  let zoneID: CKRecordZone.ID
  let repository: GRDBProfileIndexRepository

  /// Set when this handler is constructed by the shared-instrument
  /// scope; nil for test fixtures that don't wire it. When nil, every
  /// instrument-shaped record is silently dropped; the production boot
  /// path always wires the scope, so that path is unreachable in
  /// production.
  let instrumentRepository: GRDBInstrumentRegistryRepository?

  /// Fired synchronously after `applyRemoteChanges` writes one or
  /// more `InstrumentRow`s. The caller is expected to hop to
  /// `@MainActor` (this handler is nonisolated `Sendable`) and call
  /// `GRDBInstrumentRegistryRepository.notifyExternalChange()` so
  /// `observeChanges()` subscribers fan out the signal. Default is
  /// `{}` so the handler stays usable in test fixtures.
  ///
  /// Mirrors `ProfileDataSyncHandler.onInstrumentRemoteChange`'s
  /// shape exactly — same `nonisolated let @Sendable () -> Void`
  /// pattern, same fire-on-batch-with-instruments semantics.
  nonisolated let onInstrumentRemoteChange: @Sendable () -> Void

  let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileIndexSyncHandler")

  init(
    repository: GRDBProfileIndexRepository,
    instrumentRepository: GRDBInstrumentRegistryRepository? = nil,
    onInstrumentRemoteChange: @escaping @Sendable () -> Void = {}
  ) {
    self.repository = repository
    self.instrumentRepository = instrumentRepository
    self.onInstrumentRemoteChange = onInstrumentRemoteChange
    self.zoneID = CKRecordZone.ID(
      zoneName: "profile-index",
      ownerName: CKCurrentUserDefaultName
    )
  }

  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local GRDB store.
  /// Each repository's `applyRemoteChangesSync` opens its own write
  /// transaction; that's acceptable here because the two record types
  /// are independent (no `InstrumentRow` references a `ProfileRow` or
  /// vice versa), so a partial-success outcome — profiles applied,
  /// instruments failed — is a recoverable state the next sync cycle
  /// re-attempts via `unsyncedRowIdsSync()`.
  ///
  /// The single-device echo race (issue #1081) is guarded entirely inside
  /// the apply write transaction by `applyProfilesGuarded`, which reads
  /// each incoming profile row's `needs_push` flag and refuses to
  /// overwrite the field values of any row carrying an un-uploaded local
  /// edit (e.g. a profile rename). There is no main-actor pre-snapshot —
  /// the transactional check is the sole guard. Mirrors the guard in
  /// `ProfileDataSyncHandler.applyRemoteChanges` (SYNC_GUIDE §2,
  /// cross-handler review rule). Instrument rows live in the separate
  /// shared-registry database and are out of scope for the profile guard.
  func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [CKRecord.ID]
  ) -> ApplyResult {
    let savedSplit = Self.partitionSaved(saved, logger: logger)
    let deletedSplit = Self.partitionDeleted(deleted, logger: logger)

    // Profiles first, guarded by `needs_push` inside ONE transaction
    // (see `applyProfilesGuarded`).
    let appliedProfileRows: [ProfileRow]
    do {
      appliedProfileRows = try applyProfilesGuarded(
        profileRows: savedSplit.profileRows,
        deletedProfileIds: deletedSplit.profileIds,
        saved: saved)
    } catch {
      logger.error("Failed to save remote profile changes: \(error, privacy: .public)")
      return .saveFailed(error.localizedDescription)
    }

    // Instruments next (skipped when no instrument repository is wired).
    if let instrumentRepository,
      !savedSplit.instrumentRows.isEmpty || !deletedSplit.instrumentIds.isEmpty
    {
      do {
        try instrumentRepository.applyRemoteChangesSync(
          saved: savedSplit.instrumentRows, deleted: deletedSplit.instrumentIds)
        // Cross-zone observer signal — fired synchronously to keep the
        // hop into MainActor under control of the closure body.
        onInstrumentRemoteChange()
      } catch {
        logger.error(
          "Failed to save remote instrument changes: \(error, privacy: .public)")
        return .saveFailed(error.localizedDescription)
      }
    }

    var changedTypes: Set<String> = []
    if !savedSplit.profileRows.isEmpty || !deletedSplit.profileIds.isEmpty {
      changedTypes.insert(ProfileRow.recordType)
    }
    if instrumentRepository != nil,
      !savedSplit.instrumentRows.isEmpty || !deletedSplit.instrumentIds.isEmpty
    {
      changedTypes.insert(InstrumentRow.recordType)
    }
    return .profileIndexSuccess(
      changedTypes: changedTypes,
      appliedProfileRows: appliedProfileRows)
  }

  // MARK: - Building CKRecords

  /// Builds a CKRecord from a local ProfileRow for upload.
  ///
  /// If cached system fields exist on the row, applies fields directly
  /// onto the cached record to preserve the change tag and avoid
  /// `.serverRecordChanged` conflicts. If the cached system fields
  /// reference a *different* zone than this handler's own zone, they
  /// are discarded and the record is uploaded as a fresh create in the
  /// handler's zone — defence-in-depth against legacy corruption from
  /// before per-zone fetches were introduced.
  func buildCKRecord(for row: ProfileRow) -> CKRecord {
    let freshRecord = row.toCKRecord(in: zoneID)
    if let cachedData = row.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      cachedRecord.recordID.zoneID == zoneID,
      CKRecordIDRecordName.isUsableCachedRecordName(cachedRecord.recordID.recordName)
    {
      cachedRecord.replaceUserFields(with: freshRecord)
      return cachedRecord
    }
    return freshRecord
  }

  // MARK: - Record Lookup for Upload

  /// Looks up the row matching `recordID` and builds a CKRecord for
  /// upload. Dispatches by record-name shape: a UUID-decoding name
  /// goes to the profile path; any other string is treated as an
  /// instrument id and dispatched to `instrumentRepository`.
  func recordToSave(for recordID: CKRecord.ID) -> RecordLookupOutcome {
    if let profileId = recordID.uuid {
      do {
        guard let row = try repository.fetchRowSync(id: profileId) else { return .absent }
        return .found(buildCKRecord(for: row))
      } catch {
        logger.error(
          "recordToSave: failed to fetch profile row: \(error, privacy: .public) — keeping pending"
        )
        return .failed
      }
    }
    return instrumentRecordToSave(for: recordID)
  }

  // MARK: - System Fields Management

  /// Clears `encoded_system_fields` on `profile` and `instrument`
  /// rows in one transaction. Called on encrypted-data reset where
  /// the data stays but the change tags must be re-uploaded.
  func clearAllSystemFields() {
    do {
      try repository.clearAllProfileIndexSystemFieldsSync(
        instrumentRepository: instrumentRepository)
    } catch {
      logger.error("Failed to clear system fields: \(error, privacy: .public)")
    }
  }

  /// Updates `encoded_system_fields` on the row matching `recordID`.
  /// Dispatches by record-name shape (UUID → profile, otherwise →
  /// instrument).
  func updateEncodedSystemFields(_ recordID: CKRecord.ID, data: Data) {
    writeSystemFields(for: recordID, to: data)
  }

  /// Clears `encoded_system_fields` on the row matching `recordID`.
  /// Called on `.unknownItem` — the server deleted the record, so
  /// the stale change tag must be cleared so the next upload creates
  /// a fresh record.
  func clearEncodedSystemFields(_ recordID: CKRecord.ID) {
    writeSystemFields(for: recordID, to: nil)
  }

  private func writeSystemFields(for recordID: CKRecord.ID, to data: Data?) {
    do {
      if let profileId = recordID.uuid {
        try repository.setEncodedSystemFieldsBatchSync([(profileId, data)])
      } else if let instrumentRepository {
        try instrumentRepository.setEncodedSystemFieldsBatchSync(
          [(recordID.recordName, data)])
      }
    } catch {
      logger.error(
        "Failed to update system fields for \(recordID.recordName, privacy: .public): \(error, privacy: .public)"
      )
    }
  }

  // MARK: - Handle Sent Record Zone Changes

  /// Processes results from a successful CKSyncEngine send.
  /// Updates system fields on successfully saved records, classifies failures,
  /// and handles conflict/unknownItem system fields updates. Conflicts
  /// are dispatched by record type to the appropriate merge.
  /// Returns classified failures for the coordinator to re-queue.
  func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)]
  ) -> SyncErrorRecovery.ClassifiedFailures {
    var failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves,
      failedDeletes: failedDeletes,
      logger: logger)
    let persistence = persistSystemFields(for: savedRecords, failures: failures)
    if persistence.profileFailed {
      failures.requeue.append(
        contentsOf: savedRecords.compactMap { record in
          record.recordID.uuid == nil ? nil : record.recordID
        })
    }
    if persistence.instrumentFailed {
      failures.requeue.append(
        contentsOf: savedRecords.compactMap { record in
          record.recordID.uuid == nil ? record.recordID : nil
        })
    }
    return failures
  }

  /// Persists the complete sent-event system-field set in one transaction per
  /// independent backing database.
  private func persistSystemFields(
    for savedRecords: [CKRecord],
    failures: SyncErrorRecovery.ClassifiedFailures
  ) -> (profileFailed: Bool, instrumentFailed: Bool) {
    var updates: [(CKRecord.ID, Data?)] = savedRecords.map {
      ($0.recordID, $0.encodedSystemFields)
    }
    updates += failures.unknownItems.map { ($0.recordID, Optional<Data>.none) }

    var profileUpdates = updates.compactMap { recordID, data -> (UUID, Data?)? in
      guard let id = recordID.uuid else { return nil }
      return (id, data)
    }
    profileUpdates += failures.conflicts.compactMap { _, serverRecord in
      guard serverRecord.recordType == ProfileRow.recordType,
        let id = serverRecord.recordID.uuid
      else { return nil }
      return (id, serverRecord.encodedSystemFields)
    }
    let instrumentUpdates = updates.compactMap { recordID, data -> (String, Data?)? in
      guard recordID.uuid == nil else { return nil }
      return (recordID.recordName, data)
    }

    var profileFailed = false
    do {
      try persistSentProfileAcknowledgements(
        updates: profileUpdates,
        savedRecords: savedRecords,
        conflicts: failures.conflicts)
    } catch {
      profileFailed = true
      logger.error("Failed to batch profile system fields: \(error, privacy: .public)")
    }
    var instrumentFailed = false
    if let instrumentRepository {
      let conflictRows = instrumentConflictRows(from: failures.conflicts)
      do {
        try instrumentRepository.persistSentAcknowledgementsSync(
          systemFieldUpdates: instrumentUpdates,
          conflictRows: conflictRows)
      } catch {
        instrumentFailed = true
        logger.error("Failed to batch instrument system fields: \(error, privacy: .public)")
      }
    }
    return (profileFailed, instrumentFailed)
  }

  private func instrumentConflictRows(
    from conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)]
  ) -> [InstrumentRow] {
    conflicts.compactMap { _, serverRecord in
      guard serverRecord.recordType == InstrumentRow.recordType else { return nil }
      guard var row = InstrumentRow.fieldValues(from: serverRecord) else {
        logger.error(
          "Malformed instrument conflict '\(serverRecord.recordID.recordName)' — retaining old tag"
        )
        return nil
      }
      row.encodedSystemFields = serverRecord.encodedSystemFields
      return row
    }
  }
}

extension ProfileIndexSyncHandler {
  /// Promotes the local row's `dataFormatVersion` to `max(local, server)`
  /// when CKSyncEngine reports `.serverRecordChanged` for the
  /// profile-index zone. The sent-event path applies the same merge inside
  /// its acknowledgement batch transaction before CKSyncEngine retries the
  /// upload from the now-promoted local row.
  /// Without this step the re-queued save would upload the local row's
  /// stale field values, silently downgrading a higher server-side value.
  ///
  /// `internal` (not `private`) so unit tests can drive a single-record
  /// merge directly. The read-modify-write happens inside one GRDB write
  /// transaction (`mergeDataFormatVersionSync`), so concurrent writers
  /// cannot interleave and produce a stale-write race.
  func applyServerRecordChangedMerge(serverRecord: CKRecord) {
    guard let id = serverRecord.recordID.uuid else { return }
    let remote = (serverRecord["dataFormatVersion"] as? Int64).map(Int.init) ?? 0
    do {
      try repository.mergeDataFormatVersionSync(id: id, remoteValue: remote)
    } catch {
      logger.error(
        "applyServerRecordChangedMerge: \(error, privacy: .public)")
    }
  }
}
