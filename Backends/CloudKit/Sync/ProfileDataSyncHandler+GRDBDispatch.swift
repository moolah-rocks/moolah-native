@preconcurrency import CloudKit
import Foundation
import GRDB

extension ProfileDataSyncHandler {
  // MARK: - GRDB Dispatch (saves)

  /// Routes a per-record-type batch through the GRDB repos when the type
  /// has been migrated. Returns `true` when the dispatch was handled here
  /// (caller skips the SwiftData path for this group), `false` for any
  /// type not covered by the GRDB layer.
  ///
  /// `database` is the active write transaction supplied by the outer
  /// `database.write { ... }` that `applyRemoteChanges` opens for the
  /// whole fetched-changes batch (issue #872). Each per-record-type
  /// helper performs its work against this `Database` directly — no
  /// nested writes — so the entire apply lands in one commit.
  ///
  /// Throws when the GRDB write fails. The caller (`applyBatchSaves`)
  /// rethrows so `applyRemoteChanges` returns `.saveFailed(...)` and the
  /// CKSyncEngine change-token does not advance past the dropped record —
  /// the next fetch will retry instead of silently losing the update.
  nonisolated func applyGRDBBatchSave(
    recordType: String,
    ckRecords: [CKRecord],
    systemFields: [String: Data],
    in database: Database
  ) throws -> Bool {
    guard let handler = saveHandler(for: recordType) else { return false }
    try handler(self)(ckRecords, systemFields, database)
    return true
  }

  /// Returns the per-record-type save helper as a curried function,
  /// or `nil` for record types not handled by the GRDB layer. Pulling
  /// the dispatch table out of the body keeps `applyGRDBBatchSave`'s
  /// cyclomatic complexity at 2 (guard + return). The lookup itself
  /// is split between `referenceSaveHandler` (immutable reference data)
  /// and `domainSaveHandler` (the financial-graph rows) so neither
  /// switch breaches the complexity ceiling.
  nonisolated private func saveHandler(
    for recordType: String
  ) -> ((ProfileDataSyncHandler) -> ([CKRecord], [String: Data], Database) throws -> Void)? {
    referenceSaveHandler(for: recordType) ?? domainSaveHandler(for: recordType)
  }

  /// Reference-data side of the `saveHandler` lookup.
  nonisolated private func referenceSaveHandler(
    for recordType: String
  ) -> ((ProfileDataSyncHandler) -> ([CKRecord], [String: Data], Database) throws -> Void)? {
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { handler in handler.applyBatchSaveCSVImportProfile(ckRecords:systemFields:in:) }
    case ImportRuleRow.recordType:
      return { handler in handler.applyBatchSaveImportRule(ckRecords:systemFields:in:) }
    case InstrumentRow.recordType:
      return { handler in handler.applyBatchSaveInstrument(ckRecords:systemFields:in:) }
    case CategoryRow.recordType:
      return { handler in handler.applyBatchSaveCategory(ckRecords:systemFields:in:) }
    case TransferSuggestionRow.recordType:
      return { handler in
        handler.applyBatchSaveTransferSuggestion(ckRecords:systemFields:in:)
      }
    case AccountGroupRow.recordType:
      return { handler in
        handler.applyBatchSaveAccountGroup(ckRecords:systemFields:in:)
      }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `saveHandler` lookup.
  nonisolated private func domainSaveHandler(
    for recordType: String
  ) -> ((ProfileDataSyncHandler) -> ([CKRecord], [String: Data], Database) throws -> Void)? {
    switch recordType {
    case AccountRow.recordType:
      return { handler in handler.applyBatchSaveAccount(ckRecords:systemFields:in:) }
    case EarmarkRow.recordType:
      return { handler in handler.applyBatchSaveEarmark(ckRecords:systemFields:in:) }
    case EarmarkBudgetItemRow.recordType:
      return { handler in handler.applyBatchSaveEarmarkBudgetItem(ckRecords:systemFields:in:) }
    case InvestmentValueRow.recordType:
      return { handler in handler.applyBatchSaveInvestmentValue(ckRecords:systemFields:in:) }
    case TransactionRow.recordType:
      return { handler in handler.applyBatchSaveTransaction(ckRecords:systemFields:in:) }
    case TransactionLegRow.recordType:
      return { handler in handler.applyBatchSaveTransactionLeg(ckRecords:systemFields:in:) }
    default:
      return nil
    }
  }

  // MARK: - GRDB Dispatch (deletions)

  /// Routes a per-record-type batch deletion through the GRDB repos when
  /// the type has been migrated. Returns `true` when the dispatch was
  /// handled here, `false` for any type not covered by the GRDB layer.
  /// Throws on GRDB write failure so the caller can surface
  /// `.saveFailed(...)` upstream — see `applyGRDBBatchSave` for the
  /// data-loss rationale. `database` is the active write transaction
  /// from the single outer `database.write` opened by
  /// `applyRemoteChanges` (issue #872).
  nonisolated func applyGRDBBatchDeletion(
    recordType: String, ids: [UUID], in database: Database
  ) throws -> Bool {
    guard let deleter = uuidDeleter(for: recordType) else { return false }
    try deleter(self, ids, database)
    return true
  }

  /// Returns the per-record-type UUID deleter as a curried function,
  /// or `nil` for record types not handled by the GRDB layer. Mirrors
  /// the `saveHandler` shape.
  nonisolated private func uuidDeleter(
    for recordType: String
  ) -> ((ProfileDataSyncHandler, [UUID], Database) throws -> Void)? {
    referenceDeleter(for: recordType) ?? domainDeleter(for: recordType)
  }

  /// Reference-data side of the `uuidDeleter` lookup.
  nonisolated private func referenceDeleter(
    for recordType: String
  ) -> ((ProfileDataSyncHandler, [UUID], Database) throws -> Void)? {
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[CSVImportProfile]") {
          try handler.grdbRepositories.csvImportProfiles.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case ImportRuleRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[ImportRule]") {
          try handler.grdbRepositories.importRules.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case CategoryRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[Category]") {
          try handler.grdbRepositories.categories.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case TransferSuggestionRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[TransferSuggestion]") {
          try handler.grdbRepositories.transferSuggestions.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case AccountGroupRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[AccountGroup]") {
          try handler.grdbRepositories.accountGroups.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `uuidDeleter` lookup.
  nonisolated private func domainDeleter(
    for recordType: String
  ) -> ((ProfileDataSyncHandler, [UUID], Database) throws -> Void)? {
    switch recordType {
    case AccountRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[Account]") {
          try handler.grdbRepositories.accounts.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case EarmarkRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[Earmark]") {
          try handler.grdbRepositories.earmarks.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case EarmarkBudgetItemRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[EarmarkBudgetItem]") {
          try handler.grdbRepositories.earmarkBudgetItems.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case InvestmentValueRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[InvestmentValue]") {
          try handler.grdbRepositories.investmentValues.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case TransactionRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[Transaction]") {
          try handler.grdbRepositories.transactions.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    case TransactionLegRow.recordType:
      return { handler, ids, database in
        try handler.writeRemote(site: "applyGRDBBatchDeletion[TransactionLeg]") {
          try handler.grdbRepositories.transactionLegs.applyRemoteChangesSync(
            saved: [], deleted: ids, in: database)
        }
      }
    default:
      return nil
    }
  }

  /// Companion to `applyGRDBBatchDeletion(recordType:ids:)` for record
  /// types keyed by string ID. `InstrumentRecord` lives on the
  /// profile-index zone only, so any per-profile-zone deletion is a
  /// straggler from a peer device on an older build — we log and skip
  /// rather than apply. The function returns `true` to claim the
  /// dispatch slot so the engine doesn't re-route the deletion
  /// through a fallback path.
  nonisolated func applyGRDBBatchDeletion(
    recordType: String, names: [String]
  ) throws -> Bool {
    switch recordType {
    case InstrumentRow.recordType:
      guard !names.isEmpty else { return true }
      logger.warning(
        """
        Ignoring \(names.count, privacy: .public) straggler \
        InstrumentRecord deletion(s) delivered to per-profile zone \
        \(self.zoneID.zoneName, privacy: .public) — shared registry on \
        the profile-index zone is the canonical source.
        """
      )
      return true
    default:
      return false
    }
  }
}
