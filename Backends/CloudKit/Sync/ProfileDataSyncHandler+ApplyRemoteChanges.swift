// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

@preconcurrency import CloudKit
import Foundation
import GRDB
import OSLog
import os

extension ProfileDataSyncHandler {
  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local
  /// stores. The eight per-profile record types route through the GRDB
  /// dispatch tables in `+GRDBDispatch`; `ProfileRecord` is handled by
  /// `ProfileIndexSyncHandler` on the profile-index zone and is logged
  /// and skipped if it reaches this path.
  /// Returns the set of changed record type strings.
  ///
  /// The single-device echo race (issue #1081) is guarded entirely inside
  /// the apply write transaction: `applyBatchSaves` reads each incoming
  /// row's `needs_push` flag and refuses to overwrite the field values of
  /// any row that carries an un-uploaded local edit (it takes a
  /// system-fields-only update instead, advancing the change tag). There
  /// is no main-actor pre-snapshot — the transactional check is the sole
  /// guard.
  nonisolated func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)] = []
  ) -> ApplyResult {
    let batchStart = ContinuousClock.now
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
      "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID)
    }

    logIncomingBatch(saved: saved, deleted: deleted)

    let systemFields = Self.systemFieldsLookup(
      saved: saved, preExtracted: preExtractedSystemFields)

    // GRDB-routed batches throw on write failure so CKSyncEngine refetches
    // instead of advancing past a dropped record (silent data loss).
    //
    // Saves and deletions run inside a single outer `database.write` so
    // `databaseDidCommit` (and the UI `ValueObservation` re-fetches it
    // drives) fires once for the whole fetched-changes batch. Before
    // issue #872 each per-record-type group opened its own write, and a
    // single fetched batch that swapped a leg (save L_new + delete L_old)
    // surfaced an intermediate state in which both legs coexisted —
    // doubling the displayed amount in the row and the sidebar balance
    // until the next observation tick landed.
    let upsertStart = ContinuousClock.now
    if let failure = runBatchApplyPhase(
      saved: saved,
      systemFields: systemFields,
      deleted: deleted,
      signpostID: signpostID)
    {
      return failure
    }
    let upsertDuration = ContinuousClock.now - upsertStart

    return reportSuccess(
      saved: saved,
      deleted: deleted,
      timing: BatchTiming(
        batchStart: batchStart,
        upsertDuration: upsertDuration),
      signpostID: signpostID)
  }

  /// Bundles per-batch timing markers passed to `reportSuccess`. Both
  /// fields are populated up front in `applyRemoteChanges`; treat as an
  /// inline value, not shared state.
  nonisolated struct BatchTiming {
    let batchStart: ContinuousClock.Instant
    let upsertDuration: Duration
  }

  /// Runs `applyBatchSaves` and `applyBatchDeletions` inside a single
  /// outer `database.write { ... }` (issue #872), wraps each in its
  /// signpost interval for Instruments traces, and converts a thrown
  /// error into a `.saveFailed(...)` result so CKSyncEngine refetches
  /// rather than dropping a record silently. Returns `nil` on success.
  nonisolated private func runBatchApplyPhase(
    saved: [CKRecord],
    systemFields: [String: Data],
    deleted: [(CKRecord.ID, String)],
    signpostID: OSSignpostID
  ) -> ApplyResult? {
    do {
      try grdbRepositories.database.write { database in
        os_signpost(
          .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
          "%{public}d records", saved.count)
        do {
          try applyBatchSaves(saved, systemFields: systemFields, in: database)
        } catch {
          os_signpost(
            .end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)
          throw error
        }
        os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)

        os_signpost(
          .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
          "%{public}d records", deleted.count)
        do {
          try applyBatchDeletions(deleted, in: database)
        } catch {
          os_signpost(
            .end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
          throw error
        }
        os_signpost(
          .end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
      }
      return nil
    } catch {
      logger.error(
        """
        GRDB write failed during applyRemoteChanges for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return .saveFailed(error.localizedDescription)
    }
  }

  /// Records timings, fires the instrument-touched observer, and
  /// returns the success outcome.
  nonisolated private func reportSuccess(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    timing: BatchTiming,
    signpostID: OSSignpostID
  ) -> ApplyResult {
    logBatchDuration(
      batchStart: timing.batchStart,
      upsertDuration: timing.upsertDuration,
      saveCount: saved.count,
      deleteCount: deleted.count)
    let changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
    // No `onInstrumentRemoteChange()` fan-out from the per-profile
    // path: every `InstrumentRecord` flows through the shared registry
    // on the profile-index zone. Any straggler delivery here from a
    // peer device on an older build is silently logged and skipped by
    // `applyBatchSaveInstrument` / `applyGRDBBatchDeletion`. There is
    // no per-profile `instrument` table, and no UI consumer reads from
    // one.
    return .success(changedTypes: changedTypes)
  }

  // MARK: - Batch Processing

  /// Groups saved records by type and routes each group through the
  /// GRDB dispatch table. Unknown record types are logged and skipped
  /// (`ProfileRecord` is handled by `ProfileIndexSyncHandler`, not this
  /// type). `database` is the active write transaction supplied by the
  /// caller — every per-record-type group runs against it directly so
  /// the whole batch lands in one commit (issue #872).
  ///
  /// Throws when a GRDB-routed batch fails to write so the caller can
  /// return `.saveFailed(...)` and CKSyncEngine refetches instead of
  /// advancing past the dropped record (silent data loss).
  ///
  /// Within the transaction each per-type group is split by an
  /// in-transaction `needs_push` read (issue #1081): rows flagged dirty
  /// carry an in-flight local edit not yet confirmed uploaded, so their
  /// field values are NOT overwritten — they receive a system-fields-only
  /// update (advancing the change tag) in the same transaction via
  /// `applySystemFieldsInTransaction`, while clean rows take the normal
  /// `applyGRDBBatchSave` upsert. The dirty read, the clean upsert and the
  /// dirty system-fields write all share this one `database` transaction,
  /// so a fetched echo can never clobber a concurrent local edit.
  nonisolated func applyBatchSaves(
    _ records: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let grouped = Dictionary(grouping: records, by: \.recordType)
    for (recordType, ckRecords) in grouped {
      let ids = ckRecords.compactMap { $0.recordID.uuid }
      let dirty = try dirtyIds(recordType: recordType, ids: ids, in: database)
      let (clean, echoed) = Self.splitByDirtiness(ckRecords, dirty: dirty)

      if !echoed.isEmpty {
        try applySystemFieldsInTransaction(
          recordType: recordType, ckRecords: echoed, in: database)
      }
      if try applyGRDBBatchSave(
        recordType: recordType,
        ckRecords: clean,
        systemFields: systemFields,
        in: database)
      {
        continue
      }
      if recordType != ProfileRow.recordType && !clean.isEmpty {
        // The profile record type is handled by ProfileIndexSyncHandler.
        Self.batchLogger.warning(
          "applyBatchSaves: unknown record type '\(recordType)' — skipping")
      }
    }
  }

  /// Splits a per-type group into the clean records (safe to upsert) and
  /// the dirty echoes (system-fields only). The empty-`dirty` fast path
  /// keeps the common no-pending case allocation-free.
  nonisolated private static func splitByDirtiness(
    _ ckRecords: [CKRecord], dirty: Set<UUID>
  ) -> (clean: [CKRecord], echoed: [CKRecord]) {
    guard !dirty.isEmpty else { return (ckRecords, []) }
    var clean: [CKRecord] = []
    var echoed: [CKRecord] = []
    for record in ckRecords {
      if let uuid = record.recordID.uuid, dirty.contains(uuid) {
        echoed.append(record)
      } else {
        clean.append(record)
      }
    }
    return (clean, echoed)
  }

  /// Handles batch deletions. Groups by record type then routes through
  /// the GRDB dispatch tables. `database` is the active write
  /// transaction supplied by the caller (see `applyBatchSaves`).
  ///
  /// Throws when a GRDB-routed deletion batch fails. See `applyBatchSaves`
  /// for the rationale: propagating the failure ensures CKSyncEngine
  /// refetches rather than dropping the deletion record silently.
  nonisolated func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)], in database: Database
  ) throws {
    var uuidGrouped: [String: [UUID]] = [:]
    var stringGrouped: [String: [String]] = [:]

    for (recordID, recordType) in deletions {
      if let uuid = recordID.uuid {
        uuidGrouped[recordType, default: []].append(uuid)
      } else {
        stringGrouped[recordType, default: []].append(recordID.recordName)
      }
    }

    for (recordType, ids) in uuidGrouped {
      if try applyGRDBBatchDeletion(recordType: recordType, ids: ids, in: database) {
        continue
      }
      if recordType != ProfileRow.recordType {
        Self.batchLogger.warning(
          "applyBatchDeletions: unknown record type '\(recordType)' — skipping")
      }
    }
    for (recordType, names) in stringGrouped {
      // String-keyed deletions are write-free in the current dispatch
      // (only `InstrumentRow` is string-keyed, and the per-profile zone
      // drops the deletion with a warning). No `Database` argument is
      // needed; if a future record type starts writing here it should
      // accept the active `database` and stay inside this write.
      if try applyGRDBBatchDeletion(recordType: recordType, names: names) {
        continue
      }
      Self.batchLogger.warning(
        "applyBatchDeletions: unknown string-ID record type '\(recordType)' — skipping")
    }
  }

  // MARK: - Private Helpers

  /// Builds the record-name → encoded-system-fields lookup used for
  /// batch upserts. When `preExtracted` has entries the caller has
  /// already done the extraction (and filtering) and we use it directly;
  /// otherwise we synthesise it from `saved`.
  nonisolated private static func systemFieldsLookup(
    saved: [CKRecord], preExtracted: [(String, Data)]
  ) -> [String: Data] {
    let keyFor = CKRecordIDRecordName.systemFieldsKey(for:)
    if !preExtracted.isEmpty {
      return Dictionary(
        preExtracted.map { (keyFor($0.0), $0.1) },
        uniquingKeysWith: { _, last in last })
    }
    return Dictionary(
      uniqueKeysWithValues: saved.map {
        ($0.recordID.systemFieldsKey, $0.encodedSystemFields)
      }
    )
  }

  nonisolated private func logIncomingBatch(
    saved: [CKRecord], deleted: [(CKRecord.ID, String)]
  ) {
    let typeCounts = Dictionary(grouping: saved, by: \.recordType).mapValues(\.count)
    logger.info("applyRemoteChanges: \(saved.count) saves \(typeCounts), \(deleted.count) deletes")
  }

  nonisolated private func logBatchDuration(
    batchStart: ContinuousClock.Instant,
    upsertDuration: Duration,
    saveCount: Int,
    deleteCount: Int
  ) {
    let batchMs = (ContinuousClock.now - batchStart).inMilliseconds
    guard batchMs > 100 else { return }
    let upsertMs = upsertDuration.inMilliseconds
    logger.info(
      """
      applyRemoteChanges took \(batchMs)ms \
      (upsert: \(upsertMs)ms, \(saveCount) saves, \(deleteCount) deletes)
      """)
  }
}
