@preconcurrency import CloudKit
import Foundation
import OSLog
import os

extension ProfileDataSyncHandler {
  // MARK: - Queue All Existing Records

  /// Scans all record types in the local store and returns their CKRecord.IDs.
  /// Called on first start when there's no saved sync state.
  /// Returns record IDs in dependency order for the coordinator to queue.
  func queueAllExistingRecords() -> [CKRecord.ID] {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    }

    let recordIDs = collectGRDBRecordIDs(source: .all)
    if !recordIDs.isEmpty {
      logger.info("Collected \(recordIDs.count) existing records for upload")
    }
    return recordIDs
  }

  // Auto-inserted non-fiat instruments publish through the shared
  // registry on the profile-index zone: the create path calls
  // `instrumentRegistrar.registerResolvable` (production = the shared
  // `GRDBInstrumentRegistryRepository`) → `registerStock`/`registerCrypto`
  // → `fireOnRecordChanged` → `queueSave(recordName:zoneID:)` on the
  // profile-index zone. The residual self-heal lives in
  // `SyncCoordinator.queueUnsyncedSharedInstruments`.

  /// Scans all record types and returns CKRecord.IDs for records that have never been
  /// successfully sent to CloudKit (i.e. `encodedSystemFields == nil`). Used on startup
  /// to backfill uploads for profiles whose data landed via migration or any other path
  /// that bypassed the repository `onRecordChanged` hooks.
  func queueUnsyncedRecords() -> [CKRecord.ID] {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "queueUnsyncedRecords", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.sync, name: "queueUnsyncedRecords", signpostID: signpostID)
    }

    let recordIDs = collectGRDBRecordIDs(source: .unsynced)
    if !recordIDs.isEmpty {
      logger.info("Collected \(recordIDs.count) unsynced records for upload")
    }
    return recordIDs
  }

  /// Selects the per-table id source for `collectGRDBRecordIDs`:
  /// every row vs only those that have never been uploaded.
  enum GRDBIdSource {
    case all
    case unsynced
  }

  /// Walks every GRDB-backed record type in dependency order, collecting
  /// either all row ids (`.all`) or just the unsynced ones (`.unsynced`)
  /// into a single CKRecord.ID array. Centralising the table list keeps
  /// the two callers in lock-step.
  private func collectGRDBRecordIDs(source: GRDBIdSource) -> [CKRecord.ID] {
    var recordIDs: [CKRecord.ID] = []
    // Instrument ids are queued by the shared registry on the
    // profile-index zone via
    // `SyncCoordinator.queueUnsyncedSharedInstruments`; the per-profile
    // path deliberately does not enumerate them.
    collectCategoryIds(source: source, into: &recordIDs)
    collectAccountGroupIds(source: source, into: &recordIDs)
    collectInsightDismissalIds(source: source, into: &recordIDs)
    collectAccountIds(source: source, into: &recordIDs)
    collectEarmarkIds(source: source, into: &recordIDs)
    collectEarmarkBudgetItemIds(source: source, into: &recordIDs)
    collectInvestmentValueIds(source: source, into: &recordIDs)
    collectTransactionIds(source: source, into: &recordIDs)
    collectTransactionLegIds(source: source, into: &recordIDs)
    collectCSVImportProfileIds(source: source, into: &recordIDs)
    collectImportRuleIds(source: source, into: &recordIDs)
    collectTransferSuggestionIds(source: source, into: &recordIDs)
    return recordIDs
  }

  private func collectCategoryIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.categories
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: CategoryRow.recordType, into: &recordIDs)
  }

  private func collectAccountIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.accounts
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: AccountRow.recordType, into: &recordIDs)
  }

  private func collectAccountGroupIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.accountGroups
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: AccountGroupRow.recordType, into: &recordIDs)
  }

  private func collectInsightDismissalIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.insightDismissals
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(
      ids: ids, recordType: InsightDismissalRow.recordType, into: &recordIDs)
  }

  private func collectEarmarkIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.earmarks
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: EarmarkRow.recordType, into: &recordIDs)
  }

  private func collectEarmarkBudgetItemIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.earmarkBudgetItems
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: EarmarkBudgetItemRow.recordType, into: &recordIDs)
  }

  private func collectInvestmentValueIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.investmentValues
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: InvestmentValueRow.recordType, into: &recordIDs)
  }

  private func collectTransactionIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.transactions
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: TransactionRow.recordType, into: &recordIDs)
  }

  private func collectTransactionLegIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.transactionLegs
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: TransactionLegRow.recordType, into: &recordIDs)
  }

  private func collectCSVImportProfileIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.csvImportProfiles
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: CSVImportProfileRow.recordType, into: &recordIDs)
  }

  private func collectImportRuleIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.importRules
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(ids: ids, recordType: ImportRuleRow.recordType, into: &recordIDs)
  }

  private func collectTransferSuggestionIds(
    source: GRDBIdSource, into recordIDs: inout [CKRecord.ID]
  ) {
    let repo = grdbRepositories.transferSuggestions
    let ids: () throws -> [UUID] = {
      switch source {
      case .all: return try repo.allRowIdsSync()
      case .unsynced: return try repo.unsyncedRowIdsSync()
      }
    }
    collectAllGRDBUUIDs(
      ids: ids, recordType: TransferSuggestionRow.recordType, into: &recordIDs)
  }

  // MARK: - Local Data Deletion

  /// Deletes all local records for this profile's zone.
  /// Returns the set of all record type strings (for notification).
  func deleteLocalData() -> Set<String> {
    // GRDB-backed tables — wiped via the per-table repository helpers.
    // Failures are logged but never propagated; partial wipe is preferable
    // to leaving local data in an inconsistent state.
    var clearedAll = true
    for (recordType, wipe) in grdbWipes {
      do {
        try wipe()
      } catch {
        clearedAll = false
        logger.error(
          """
          Failed to delete \(recordType, privacy: .public) from GRDB for profile \
          \(self.profileId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    if clearedAll {
      logger.info("Deleted all local data for profile \(self.profileId)")
    }
    // Always return all types so the caller fans out the change
    // notification even on partial failure.
    return Set(RecordTypeRegistry.allTypes.keys)
  }

  /// Per-record-type GRDB wipe closures consulted by `deleteLocalData()`.
  ///
  /// No per-profile `instrument` wipe. Instrument data is owned by the
  /// shared, iCloud-account-scoped profile-index registry, and a
  /// single-profile purge (sign-out / account-switch / zone purge) must
  /// NOT wipe instruments shared by every other profile. There is no
  /// per-profile `instrument` table, so a `deleteAllSync` against it
  /// would throw `no such table`.
  private var grdbWipes: [(String, () throws -> Void)] {
    [
      (CategoryRow.recordType, { try self.grdbRepositories.categories.deleteAllSync() }),
      (
        AccountGroupRow.recordType,
        { try self.grdbRepositories.accountGroups.deleteAllSync() }
      ),
      (
        InsightDismissalRow.recordType,
        { try self.grdbRepositories.insightDismissals.deleteAllSync() }
      ),
      (AccountRow.recordType, { try self.grdbRepositories.accounts.deleteAllSync() }),
      (EarmarkRow.recordType, { try self.grdbRepositories.earmarks.deleteAllSync() }),
      (
        EarmarkBudgetItemRow.recordType,
        { try self.grdbRepositories.earmarkBudgetItems.deleteAllSync() }
      ),
      (
        InvestmentValueRow.recordType,
        { try self.grdbRepositories.investmentValues.deleteAllSync() }
      ),
      (TransactionRow.recordType, { try self.grdbRepositories.transactions.deleteAllSync() }),
      (
        TransactionLegRow.recordType,
        { try self.grdbRepositories.transactionLegs.deleteAllSync() }
      ),
      (
        CSVImportProfileRow.recordType,
        { try self.grdbRepositories.csvImportProfiles.deleteAllSync() }
      ),
      (ImportRuleRow.recordType, { try self.grdbRepositories.importRules.deleteAllSync() }),
      (
        TransferSuggestionRow.recordType,
        { try self.grdbRepositories.transferSuggestions.deleteAllSync() }
      ),
      // Clear pending deletion intents too (issue #1090): a local teardown
      // (sign-out / account-switch / zone purge) must not leave tombstones that
      // would replay as `.deleteRecord`s on the next sign-in.
      (
        "deletion_journal",
        {
          try self.grdbRepositories.database.write { database in
            try DeletionJournal.clearAll(in: database)
          }
        }
      ),
    ]
  }

  // MARK: - Private Helpers

  /// Reads UUIDs from a GRDB-backed repo and appends one prefixed
  /// `CKRecord.ID` per id. The closure is the synchronous repo entry
  /// point (e.g. `allRowIdsSync` / `unsyncedRowIdsSync`); fetch failures
  /// are logged and produce zero records (mirroring `fetchOrLog`'s
  /// best-effort semantics).
  private func collectAllGRDBUUIDs(
    ids: () throws -> [UUID],
    recordType: String,
    into recordIDs: inout [CKRecord.ID]
  ) {
    do {
      for id in try ids() {
        recordIDs.append(
          CKRecord.ID(recordType: recordType, uuid: id, zoneID: zoneID))
      }
    } catch {
      logger.error(
        """
        GRDB fetch failed for \(recordType, privacy: .public) on profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  // `collectAllGRDBStrings` was the string-keyed counterpart of
  // `collectAllGRDBUUIDs`, used by the now-decommissioned per-profile
  // `queueUnsyncedInstrumentRecords` path. Removed alongside its only
  // caller — instrument-id enumeration lives entirely on the shared
  // registry via `SyncCoordinator.queueUnsyncedSharedInstruments`.
}
