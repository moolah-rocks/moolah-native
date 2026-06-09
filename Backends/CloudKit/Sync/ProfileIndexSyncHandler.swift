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
/// force every caller to block the UI thread; instead, callers that
/// care can hop off-actor (`Task.detached { handler.deleteLocalData() }`).
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
  /// `locallyPendingRecordNames` carries the record names that currently
  /// have an un-uploaded local change queued for this zone (saves *and*
  /// deletes). A fetched save for one of these is a stale server echo of
  /// an earlier version — applying its field values would clobber the
  /// not-yet-uploaded local edit (e.g. a profile rename, or an instrument
  /// pricing-status change). Such records are excluded from the
  /// field-value upsert and routed through a system-fields-only update
  /// (`writeSystemFields`), so the cached change tag advances while the
  /// local field values win on the next send. Mirrors the guard in
  /// `ProfileDataSyncHandler.applyRemoteChanges` (SYNC_GUIDE §2,
  /// cross-handler review rule).
  func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [CKRecord.ID],
    locallyPendingRecordNames: Set<String> = []
  ) -> ApplyResult {
    let (freshSaved, pendingEchoes) = Self.partitionPendingEchoes(
      saved: saved, locallyPendingRecordNames: locallyPendingRecordNames)
    if !pendingEchoes.isEmpty {
      logger.info(
        """
        applyRemoteChanges: \(pendingEchoes.count) fetched save(s) match locally-pending \
        records — applying system fields only, preserving in-flight local edits
        """)
      for record in pendingEchoes {
        writeSystemFields(for: record.recordID, to: record.encodedSystemFields)
      }
    }

    let savedSplit = Self.partitionSaved(freshSaved, logger: logger)
    let deletedSplit = Self.partitionDeleted(deleted, logger: logger)

    // Profiles first, guarded by `needs_push` inside ONE transaction
    // (see `applyProfilesGuarded`).
    do {
      try applyProfilesGuarded(
        profileRows: savedSplit.profileRows,
        deletedProfileIds: deletedSplit.profileIds,
        freshSaved: freshSaved)
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
    return .success(changedTypes: changedTypes)
  }

  /// Partitions fetched saves into the records safe to upsert
  /// (`fresh`) and the stale echoes of locally-pending records
  /// (`pendingEchoes`) whose field values must not be overwritten.
  /// The empty-set fast path keeps the common (no-pending) case
  /// allocation-free. Mirrors the same-named helper on
  /// `ProfileDataSyncHandler` (the two handlers are maintained
  /// separately per SYNC_GUIDE §2).
  static func partitionPendingEchoes(
    saved: [CKRecord], locallyPendingRecordNames: Set<String>
  ) -> (fresh: [CKRecord], pendingEchoes: [CKRecord]) {
    guard !locallyPendingRecordNames.isEmpty else { return (saved, []) }
    var fresh: [CKRecord] = []
    var pendingEchoes: [CKRecord] = []
    for record in saved {
      if locallyPendingRecordNames.contains(record.recordID.recordName) {
        pendingEchoes.append(record)
      } else {
        fresh.append(record)
      }
    }
    return (fresh, pendingEchoes)
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
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  // MARK: - Record Lookup for Upload

  /// Looks up the row matching `recordID` and builds a CKRecord for
  /// upload. Dispatches by record-name shape: a UUID-decoding name
  /// goes to the profile path; any other string is treated as an
  /// instrument id and dispatched to `instrumentRepository`.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    if let profileId = recordID.uuid {
      do {
        guard let row = try repository.fetchRowSync(id: profileId) else { return nil }
        return buildCKRecord(for: row)
      } catch {
        logger.error("recordToSave: failed to fetch profile row: \(error, privacy: .public)")
        return nil
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
    persistSystemFields(for: savedRecords)
    clearNeedsPushForConfirmed(savedRecords)
    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves,
      failedDeletes: failedDeletes,
      logger: logger)
    resolveSystemFields(for: failures)
    for (_, serverRecord) in failures.conflicts {
      switch serverRecord.recordType {
      case ProfileRow.recordType:
        applyServerRecordChangedMerge(serverRecord: serverRecord)
      case InstrumentRow.recordType:
        applyInstrumentServerRecordChangedMerge(serverRecord: serverRecord)
      default:
        logger.error(
          "handleSentRecordZoneChanges: unexpected recordType '\(serverRecord.recordType, privacy: .public)' on profile-index zone — ignoring"
        )
      }
    }
    return failures
  }

  /// Persist updated CKRecord system fields onto matching rows after
  /// a successful upload. Dispatches by record-name shape.
  private func persistSystemFields(for savedRecords: [CKRecord]) {
    guard !savedRecords.isEmpty else { return }
    for saved in savedRecords {
      writeSystemFields(for: saved.recordID, to: saved.encodedSystemFields)
    }
  }

  /// Apply server-side system fields from conflicts, and clear system
  /// fields for records the server has already deleted.
  private func resolveSystemFields(for failures: SyncErrorRecovery.ClassifiedFailures) {
    guard !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty else { return }
    for (_, serverRecord) in failures.conflicts {
      writeSystemFields(for: serverRecord.recordID, to: serverRecord.encodedSystemFields)
    }
    for (recordID, _) in failures.unknownItems {
      writeSystemFields(for: recordID, to: nil)
    }
  }

  /// Look up a row by id and replace its cached system fields blob.
  /// Dispatches by record-name shape: a UUID-decoding name goes to
  /// the profile path; otherwise the name is the instrument id.
  private func writeSystemFields(for recordID: CKRecord.ID, to data: Data?) {
    if let profileId = recordID.uuid {
      do {
        _ = try repository.setEncodedSystemFieldsSync(id: profileId, data: data)
      } catch {
        logger.error(
          "Failed to save profile system fields for \(recordID.recordName, privacy: .public): \(error, privacy: .public)"
        )
      }
      return
    }
    guard let instrumentRepository else { return }
    do {
      _ = try instrumentRepository.setEncodedSystemFieldsSync(
        id: recordID.recordName, data: data)
    } catch {
      logger.error(
        "Failed to save instrument system fields for \(recordID.recordName, privacy: .public): \(error, privacy: .public)"
      )
    }
  }
}

extension ProfileIndexSyncHandler {
  /// Promotes the local row's `dataFormatVersion` to `max(local, server)`
  /// when CKSyncEngine reports `.serverRecordChanged` for the
  /// profile-index zone. Called from `handleSentRecordZoneChanges` after
  /// `resolveSystemFields(for: failures)` and before the method returns
  /// (CKSyncEngine retries the upload from the now-promoted local row).
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
