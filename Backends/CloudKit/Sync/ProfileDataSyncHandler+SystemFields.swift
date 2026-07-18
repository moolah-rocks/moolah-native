@preconcurrency import CloudKit
import Foundation
import GRDB
import os

extension ProfileDataSyncHandler {
  // MARK: - System Fields Management

  /// Clears `encodedSystemFields` on every locally-tracked row.
  /// Called before re-uploading after an `encryptedDataReset`.
  func clearAllSystemFields() {
    let clearedAll = runSystemFieldClears(clearOperations())
    if clearedAll {
      logger.info("Cleared all system fields for profile \(self.profileId)")
    }
  }

  /// Per-record-type clear operations, listed in the same dependency
  /// order `deleteLocalData()` uses (parents before children, with the
  /// CSV-import / import-rule pair at the end). Independent updates so
  /// the order doesn't affect correctness, but matching the two lists
  /// keeps a future maintainer from getting them out of step when a
  /// new record type is added.
  private func clearOperations() -> [(String, () throws -> Void)] {
    // `InstrumentRow.recordType` intentionally omitted: there is no
    // per-profile `instrument` table. No upload path consults system
    // fields on instrument rows, so they have nothing to clear.
    [
      (TaxOwnerRow.recordType, grdbRepositories.taxOwners.clearAllSystemFieldsSync),
      (CategoryRow.recordType, grdbRepositories.categories.clearAllSystemFieldsSync),
      (AccountRow.recordType, grdbRepositories.accounts.clearAllSystemFieldsSync),
      (AccountGroupRow.recordType, grdbRepositories.accountGroups.clearAllSystemFieldsSync),
      (
        InsightDismissalRow.recordType,
        grdbRepositories.insightDismissals.clearAllSystemFieldsSync
      ),
      (
        WalletSyncCheckpointRow.recordType,
        grdbRepositories.walletSyncCheckpoints.clearAllSystemFieldsSync
      ),
      (EarmarkRow.recordType, grdbRepositories.earmarks.clearAllSystemFieldsSync),
      (
        EarmarkBudgetItemRow.recordType,
        grdbRepositories.earmarkBudgetItems.clearAllSystemFieldsSync
      ),
      (TransactionRow.recordType, grdbRepositories.transactions.clearAllSystemFieldsSync),
      (TransactionLegRow.recordType, grdbRepositories.transactionLegs.clearAllSystemFieldsSync),
      (CSVImportProfileRow.recordType, grdbRepositories.csvImportProfiles.clearAllSystemFieldsSync),
      (ImportRuleRow.recordType, grdbRepositories.importRules.clearAllSystemFieldsSync),
      (
        TransferSuggestionRow.recordType,
        grdbRepositories.transferSuggestions.clearAllSystemFieldsSync
      ),
    ]
  }

  /// Runs the per-record-type clears; logs and continues on failure so
  /// a single broken table cannot leave others stuck. Returns `true`
  /// when every operation succeeded.
  private func runSystemFieldClears(
    _ clears: [(String, () throws -> Void)]
  ) -> Bool {
    var clearedAll = true
    for (recordType, clear) in clears {
      do {
        try clear()
      } catch {
        clearedAll = false
        logger.error(
          """
          Failed to clear system fields for \(recordType, privacy: .public) profile \
          \(self.profileId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    return clearedAll
  }

  // MARK: - Handle Sent Record Zone Changes

  /// Processes results from a successful CKSyncEngine send.
  /// Updates system fields on successfully saved records, classifies failures,
  /// and handles conflict/unknownItem system fields updates.
  /// Returns classified failures for the coordinator to re-queue.
  /// Runs the complete acknowledgement persistence sequence away from the
  /// caller's actor. `@concurrent` makes the off-actor executor guarantee
  /// explicit across both Swift 6.2 concurrency modes.
  @concurrent
  nonisolated func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)]
  ) async -> SyncErrorRecovery.ClassifiedFailures {
    precondition(
      !Thread.isMainThread,
      "Sent-record acknowledgement persistence must not run on the main thread")
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin,
      log: Signposts.sync,
      name: "persistSentAcknowledgements",
      signpostID: signpostID,
      "%{public}d saved records",
      savedRecords.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.sync,
        name: "persistSentAcknowledgements",
        signpostID: signpostID)
    }

    var failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves, failedDeletes: failedDeletes, logger: logger)
    do {
      try persistSentAcknowledgementChanges(
        savedRecords: savedRecords, failures: failures)
    } catch {
      logger.error(
        "Sent acknowledgement transaction failed: \(error.localizedDescription, privacy: .public)"
      )
      // CKSyncEngine removes successful saves from its pending queue. If their
      // local acknowledgement transaction rolls back, retry them so system
      // fields and needs_push cannot diverge.
      failures.requeue.append(contentsOf: savedRecords.map(\.recordID))
    }

    return failures
  }

  /// Persists the complete sent-event acknowledgement in one GRDB write so a
  /// setter failure rolls back system fields and needs_push together.
  nonisolated private func persistSentAcknowledgementChanges(
    savedRecords: [CKRecord],
    failures: SyncErrorRecovery.ClassifiedFailures
  ) throws {
    try grdbRepositories.database.write { database in
      var preAckCached: [String: Data?] = [:]
      for saved in savedRecords {
        guard let uuid = saved.recordID.uuid else { continue }
        if let blob = try self.cachedSystemFields(
          recordType: saved.recordType, id: uuid, in: database)
        {
          preAckCached[saved.recordID.systemFieldsKey] = blob
        }
      }

      try self.applySystemFieldsInTransaction(
        savedRecords, in: database)
      try self.clearNeedsPushForConfirmed(
        savedRecords, preAckCached: preAckCached, in: database)
      try self.applySystemFieldsInTransaction(
        failures.conflicts.map(\.serverRecord), in: database)

      let unknownUpdates = Dictionary(grouping: failures.unknownItems, by: \.recordType)
      for (recordType, items) in unknownUpdates {
        let updates = items.compactMap { item -> (id: UUID, data: Data?)? in
          guard let id = item.recordID.uuid else { return nil }
          return (id: id, data: nil)
        }
        _ = try self.applySystemFieldUpdatesInTransaction(
          recordType: recordType, updates: updates, in: database)
      }
    }
    logger.info("Persisted sent acknowledgements for \(savedRecords.count) saved records")
  }

  nonisolated private func applySystemFieldsInTransaction(
    _ records: [CKRecord], in database: Database
  ) throws {
    let recordsByType = Dictionary(grouping: records, by: \.recordType)
    for (recordType, typedRecords) in recordsByType {
      try applySystemFieldsInTransaction(
        recordType: recordType, ckRecords: typedRecords, in: database)
    }
  }

  /// Clears `needs_push` for each saved record whose current local row
  /// still matches the uploaded version AND that has never round-tripped
  /// before (its pre-ack cached system fields were `nil`). A row with a
  /// non-`nil` pre-ack blob was uploaded at an earlier server version; a
  /// stale echo of that superseded version may still be queued in the
  /// fetch backlog, and clearing the flag here would let that echo clobber
  /// this newer edit on the clean apply path (the step-5→6 single-device
  /// loss window). For those rows the flag stays set and is cleared later
  /// by the fetch/apply path when the *confirming* echo of the current
  /// version arrives. Even once cleared, a superseded stale echo that
  /// arrives afterwards cannot clobber the row: the modification-date gate
  /// on the clean apply path (`applyBatchSaves`, issue #1085) rejects any
  /// echo whose server `modificationDate` is not strictly newer than the
  /// date the row caches. CloudKit does **not** guarantee fetched changes
  /// arrive in server-token order; the date gate provides the guarantee. Clearing only
  /// on an exact user-field match remains the safe direction — an
  /// under-clear is a harmless extra deferral, while an over-clear could let
  /// a later echo clobber a pending newer edit (data loss).
  ///
  /// **Atomicity (issue #1081).** The current-row read, the user-field
  /// compare, and the conditional clear all run inside ONE
  /// `grdbRepositories.database.write` transaction. Because that write
  /// holds the serial GRDB queue for its whole duration, no concurrent
  /// local edit can commit (and re-raise `needs_push`) between the compare
  /// and the clear. Splitting the read and write would create a TOCTOU window
  /// where that interleaving could clear the flag over a newer edit.
  ///
  /// - Precondition: call off the main thread through the acknowledgement
  ///   handler's `@concurrent` boundary. The single `database.write` is the
  ///   only transaction opened, so this must not be nested inside another
  ///   write on the same queue.
  nonisolated private func clearNeedsPushForConfirmed(
    _ savedRecords: [CKRecord],
    preAckCached: [String: Data?],
    in database: Database
  ) throws {
    var clearByType: [String: [UUID]] = [:]
    for saved in savedRecords {
      guard let uuid = saved.recordID.uuid else { continue }
      guard case .some(.none) = preAckCached[saved.recordID.systemFieldsKey]
      else { continue }
      guard
        let current = try currentCKRecord(
          recordType: saved.recordType, id: uuid, in: database)
      else { continue }
      if current.hasSameUserFields(as: saved) {
        clearByType[saved.recordType, default: []].append(uuid)
      }
    }
    for (recordType, ids) in clearByType {
      try clearNeedsPush(recordType: recordType, ids: ids, in: database)
    }
  }

  /// Groups `ckRecords` by recordType and runs one batch system-fields
  /// write per type. `InstrumentRecord` deliveries on a per-profile
  /// zone are straggler state (there is no per-profile `instrument`
  /// table) and are logged-and-skipped. Records with non-UUID
  /// recordNames are also skipped.
  ///
  /// `nonisolated` (and not `private`) so the off-main fetched-changes
  /// apply path can reconcile stale echoes of locally-pending records
  /// through it — updating only the cached change tag, never field
  /// values. Touches only `nonisolated let` state (`logger`, `zoneID`,
  /// `grdbRepositories`).
  ///
  /// - Precondition: Must not be called while a write transaction is
  ///   open on `grdbRepositories.database`. Each per-type setter opens
  ///   its own `database.write`; calling from inside an outer
  ///   `database.write` on the same serial `DatabaseQueue` deadlocks.
  ///   The fetched-changes caller invokes this only *after* its outer
  ///   batch write commits.
  nonisolated func applySystemFieldsBatched(_ ckRecords: [CKRecord]) {
    var updatesByType: [String: [(id: UUID, data: Data?)]] = [:]
    for ckRecord in ckRecords {
      if ckRecord.recordType == InstrumentRow.recordType {
        logger.warning(
          """
          Ignoring straggler InstrumentRecord system-fields apply for \
          \(ckRecord.recordID.recordName, privacy: .public) on per-profile zone \
          \(self.zoneID.zoneName, privacy: .public).
          """)
        continue
      }
      guard let uuid = ckRecord.recordID.uuid else {
        logger.warning(
          "applySystemFields: recordName \(ckRecord.recordID.recordName) has no UUID component for \(ckRecord.recordType)"
        )
        continue
      }
      updatesByType[ckRecord.recordType, default: []]
        .append((id: uuid, data: ckRecord.encodedSystemFields))
    }
    for (recordType, updates) in updatesByType {
      runBatchedSystemFieldsUpdate(recordType: recordType, updates: updates)
    }
  }

  /// Dispatches one batch system-fields write through the GRDB repo
  /// for `recordType`. A miss on the dispatch table or a thrown error
  /// is logged at warning / error and the next type still runs.
  nonisolated private func runBatchedSystemFieldsUpdate(
    recordType: String, updates: [(id: UUID, data: Data?)]
  ) {
    guard let setter = systemFieldsBatchSetter(for: recordType) else {
      logger.warning(
        "No GRDB dispatch for \(recordType, privacy: .public) batch system-fields update"
      )
      return
    }
    do {
      let updatedCount = try setter(updates)
      if updatedCount < updates.count {
        logger.warning(
          """
          Batch system-fields update found \(updatedCount, privacy: .public) of \
          \(updates.count, privacy: .public) rows for \
          \(recordType, privacy: .public)
          """)
      }
    } catch {
      logger.error(
        """
        GRDB batch system-fields update failed for \(recordType, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  /// Returns the per-recordType batch system-fields setter, or `nil`
  /// for record types not handled by the GRDB layer. The lookup is
  /// split between `referenceSystemFieldsBatchSetter` (immutable
  /// reference data) and `domainSystemFieldsBatchSetter` (the
  /// financial-graph rows) so neither switch breaches the
  /// cyclomatic-complexity ceiling — same shape as `saveHandler`.
  nonisolated private func systemFieldsBatchSetter(
    for recordType: String
  ) -> (([(id: UUID, data: Data?)]) throws -> Int)? {
    referenceSystemFieldsBatchSetter(for: recordType)
      ?? domainSystemFieldsBatchSetter(for: recordType)
  }

  /// Reference-data side of the `systemFieldsBatchSetter` lookup.
  nonisolated private func referenceSystemFieldsBatchSetter(
    for recordType: String
  ) -> (([(id: UUID, data: Data?)]) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { try repos.csvImportProfiles.setEncodedSystemFieldsBatchSync($0) }
    case ImportRuleRow.recordType:
      return { try repos.importRules.setEncodedSystemFieldsBatchSync($0) }
    case CategoryRow.recordType:
      return { try repos.categories.setEncodedSystemFieldsBatchSync($0) }
    case TaxOwnerRow.recordType:
      return { try repos.taxOwners.setEncodedSystemFieldsBatchSync($0) }
    case TransferSuggestionRow.recordType:
      return { try repos.transferSuggestions.setEncodedSystemFieldsBatchSync($0) }
    case AccountGroupRow.recordType:
      return { try repos.accountGroups.setEncodedSystemFieldsBatchSync($0) }
    case InsightDismissalRow.recordType:
      return { try repos.insightDismissals.setEncodedSystemFieldsBatchSync($0) }
    case WalletSyncCheckpointRow.recordType:
      return { try repos.walletSyncCheckpoints.setEncodedSystemFieldsBatchSync($0) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `systemFieldsBatchSetter` lookup.
  nonisolated private func domainSystemFieldsBatchSetter(
    for recordType: String
  ) -> (([(id: UUID, data: Data?)]) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return { try repos.accounts.setEncodedSystemFieldsBatchSync($0) }
    case EarmarkRow.recordType:
      return { try repos.earmarks.setEncodedSystemFieldsBatchSync($0) }
    case EarmarkBudgetItemRow.recordType:
      return { try repos.earmarkBudgetItems.setEncodedSystemFieldsBatchSync($0) }
    case TransactionRow.recordType:
      return { try repos.transactions.setEncodedSystemFieldsBatchSync($0) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.setEncodedSystemFieldsBatchSync($0) }
    default:
      return nil
    }
  }
}
