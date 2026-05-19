@preconcurrency import CloudKit
import Foundation

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
      (CategoryRow.recordType, grdbRepositories.categories.clearAllSystemFieldsSync),
      (AccountRow.recordType, grdbRepositories.accounts.clearAllSystemFieldsSync),
      (EarmarkRow.recordType, grdbRepositories.earmarks.clearAllSystemFieldsSync),
      (
        EarmarkBudgetItemRow.recordType,
        grdbRepositories.earmarkBudgetItems.clearAllSystemFieldsSync
      ),
      (InvestmentValueRow.recordType, grdbRepositories.investmentValues.clearAllSystemFieldsSync),
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
  func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)]
  ) -> SyncErrorRecovery.ClassifiedFailures {
    if !savedRecords.isEmpty {
      updateSystemFieldsForSaved(savedRecords)
    }

    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves, failedDeletes: failedDeletes, logger: logger)

    if !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty {
      updateSystemFieldsForFailures(
        conflicts: failures.conflicts, unknownItems: failures.unknownItems)
    }

    return failures
  }

  /// Writes each successfully-sent record's latest system fields back
  /// onto the matching local row, batching the writes by recordType so
  /// that one CKSyncEngine batch produces one GRDB commit per
  /// recordType (not one per record). Reduces the
  /// `databaseDidCommit`-driven UI re-fetch cost during sync uploads.
  /// See issue #865 for the follow-up that lifts the observation
  /// region's dependency on the column itself.
  private func updateSystemFieldsForSaved(_ savedRecords: [CKRecord]) {
    applySystemFieldsBatched(savedRecords)
    logger.info("Applied system fields for \(savedRecords.count) saved records")
  }

  /// Reconciles system fields after conflicts (adopt the server copy)
  /// and unknownItem failures (clear the stale cache so the record
  /// re-uploads as a fresh create). Both paths batch by recordType
  /// for the same reason `updateSystemFieldsForSaved` does.
  private func updateSystemFieldsForFailures(
    conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)],
    unknownItems: [(recordID: CKRecord.ID, recordType: String)]
  ) {
    if !conflicts.isEmpty {
      applySystemFieldsBatched(conflicts.map(\.serverRecord))
    }
    if !unknownItems.isEmpty {
      clearSystemFieldsBatched(unknownItems)
    }
  }

  /// Groups `ckRecords` by recordType and runs one batch system-fields
  /// write per type. `InstrumentRecord` deliveries on a per-profile
  /// zone are straggler state (there is no per-profile `instrument`
  /// table) and are logged-and-skipped. Records with non-UUID
  /// recordNames are also skipped.
  private func applySystemFieldsBatched(_ ckRecords: [CKRecord]) {
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

  /// Same shape as `applySystemFieldsBatched` but for unknownItem
  /// failures: groups by recordType and runs one batch clear (data
  /// = `nil`) per type.
  private func clearSystemFieldsBatched(
    _ unknownItems: [(recordID: CKRecord.ID, recordType: String)]
  ) {
    var updatesByType: [String: [(id: UUID, data: Data?)]] = [:]
    for (recordID, recordType) in unknownItems {
      if recordType == InstrumentRow.recordType {
        logger.warning(
          """
          Ignoring straggler InstrumentRecord system-fields clear for \
          \(recordID.recordName, privacy: .public) on per-profile zone \
          \(self.zoneID.zoneName, privacy: .public).
          """)
        continue
      }
      guard let uuid = recordID.uuid else {
        logger.warning(
          "clearSystemFields: recordName \(recordID.recordName) has no UUID component for \(recordType)"
        )
        continue
      }
      updatesByType[recordType, default: []].append((id: uuid, data: nil))
    }
    for (recordType, updates) in updatesByType {
      runBatchedSystemFieldsUpdate(recordType: recordType, updates: updates)
    }
  }

  /// Dispatches one batch system-fields write through the GRDB repo
  /// for `recordType`. A miss on the dispatch table or a thrown error
  /// is logged at warning / error and the next type still runs.
  private func runBatchedSystemFieldsUpdate(
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
  private func systemFieldsBatchSetter(
    for recordType: String
  ) -> (([(id: UUID, data: Data?)]) throws -> Int)? {
    referenceSystemFieldsBatchSetter(for: recordType)
      ?? domainSystemFieldsBatchSetter(for: recordType)
  }

  /// Reference-data side of the `systemFieldsBatchSetter` lookup.
  private func referenceSystemFieldsBatchSetter(
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
    case TransferSuggestionRow.recordType:
      return { try repos.transferSuggestions.setEncodedSystemFieldsBatchSync($0) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `systemFieldsBatchSetter` lookup.
  private func domainSystemFieldsBatchSetter(
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
    case InvestmentValueRow.recordType:
      return { try repos.investmentValues.setEncodedSystemFieldsBatchSync($0) }
    case TransactionRow.recordType:
      return { try repos.transactions.setEncodedSystemFieldsBatchSync($0) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.setEncodedSystemFieldsBatchSync($0) }
    default:
      return nil
    }
  }
}
