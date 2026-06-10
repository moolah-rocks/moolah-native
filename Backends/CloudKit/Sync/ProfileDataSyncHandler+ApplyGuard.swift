@preconcurrency import CloudKit
import Foundation
import GRDB

extension ProfileDataSyncHandler {
  // MARK: - needs_push apply guard (issue #1081)

  /// Returns the subset of `ids` whose `recordType` row currently has
  /// `needs_push = 1`, read **inside** the active apply write `database`
  /// (no separate read). A dirty row carries an in-flight local edit not
  /// yet confirmed uploaded; the apply path skips its field-value upsert
  /// and advances only its change tag so a stale echo can never clobber
  /// the newer local edit. Unknown record types report no dirty ids.
  ///
  /// The lookup is split between `referenceDirtyIdsReader` (reference
  /// data) and `domainDirtyIdsReader` (financial-graph rows) so neither
  /// switch breaches the cyclomatic-complexity ceiling — same shape as
  /// `saveHandler`.
  nonisolated func dirtyIds(
    recordType: String, ids: [UUID], in database: Database
  ) throws -> Set<UUID> {
    guard
      let reader = referenceDirtyIdsReader(for: recordType)
        ?? domainDirtyIdsReader(for: recordType)
    else { return [] }
    return try reader(ids, database)
  }

  /// Reference-data side of the `dirtyIds` lookup.
  nonisolated private func referenceDirtyIdsReader(
    for recordType: String
  ) -> (([UUID], Database) throws -> Set<UUID>)? {
    let repos = grdbRepositories
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { try repos.csvImportProfiles.dirtyIdsSync(from: $0, in: $1) }
    case ImportRuleRow.recordType:
      return { try repos.importRules.dirtyIdsSync(from: $0, in: $1) }
    case CategoryRow.recordType:
      return { try repos.categories.dirtyIdsSync(from: $0, in: $1) }
    case TransferSuggestionRow.recordType:
      return { try repos.transferSuggestions.dirtyIdsSync(from: $0, in: $1) }
    case AccountGroupRow.recordType:
      return { try repos.accountGroups.dirtyIdsSync(from: $0, in: $1) }
    case InsightDismissalRow.recordType:
      return { try repos.insightDismissals.dirtyIdsSync(from: $0, in: $1) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `dirtyIds` lookup.
  nonisolated private func domainDirtyIdsReader(
    for recordType: String
  ) -> (([UUID], Database) throws -> Set<UUID>)? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return { try repos.accounts.dirtyIdsSync(from: $0, in: $1) }
    case EarmarkRow.recordType:
      return { try repos.earmarks.dirtyIdsSync(from: $0, in: $1) }
    case EarmarkBudgetItemRow.recordType:
      return { try repos.earmarkBudgetItems.dirtyIdsSync(from: $0, in: $1) }
    case InvestmentValueRow.recordType:
      return { try repos.investmentValues.dirtyIdsSync(from: $0, in: $1) }
    case TransactionRow.recordType:
      return { try repos.transactions.dirtyIdsSync(from: $0, in: $1) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.dirtyIdsSync(from: $0, in: $1) }
    default:
      return nil
    }
  }

  // MARK: - needs_push confirming-echo clear (issue #1081 follow-up)

  /// Clears `needs_push` for dirty rows whose fetched echo carries the
  /// SAME user fields as the current local row — the round-trip is
  /// complete (the version the device last uploaded has now come back via
  /// fetch). Runs **inside** the active apply `database`, after the
  /// echoes' system-fields-only update, so the compare and clear share one
  /// transaction.
  ///
  /// **Why this is the safe place to clear (not the upload ack).** The
  /// upload-ack path deliberately leaves `needs_push` set for any row that
  /// has round-tripped before (issue #1081 follow-up), because a stale
  /// echo of a *superseded* earlier version may still be queued in the
  /// fetch backlog and would clobber the newer edit on the clean path. By
  /// the time the *confirming* echo of the current version is fetched,
  /// every earlier-token stale echo has already been delivered — CKSyncEngine
  /// streams fetched changes in monotonic server-token order — so clearing
  /// here cannot reopen the window. A genuine remote change carries
  /// *different* user fields, so it never matches and never clears the
  /// flag; it is handled by the normal pending-guard / conflict path.
  nonisolated func clearNeedsPushForConfirmingEchoes(
    recordType: String, ckRecords: [CKRecord], in database: Database
  ) throws {
    var confirmedIds: [UUID] = []
    for echo in ckRecords {
      guard let uuid = echo.recordID.uuid else { continue }
      guard
        let current = try currentCKRecord(recordType: recordType, id: uuid, in: database)
      else { continue }
      if current.hasSameUserFields(as: echo) {
        confirmedIds.append(uuid)
      }
    }
    guard !confirmedIds.isEmpty else { return }
    try clearNeedsPush(recordType: recordType, ids: confirmedIds, in: database)
  }

  // MARK: - needs_push conditional clear (issue #1081)

  /// Clears `needs_push` for `ids` of `recordType` (each repo's
  /// `clearNeedsPushBatchSync` opens its own write). Called from the
  /// upload-ack path only for ids whose current row still matches the
  /// uploaded version. Unknown record types are a no-op. Dispatch is
  /// split into reference / domain halves for the same complexity reason
  /// as `dirtyIds`.
  nonisolated func clearNeedsPush(recordType: String, ids: [UUID]) throws {
    guard
      let clear = referenceNeedsPushClearer(for: recordType)
        ?? domainNeedsPushClearer(for: recordType)
    else { return }
    _ = try clear(ids)
  }

  /// In-transaction counterpart to `clearNeedsPush(recordType:ids:)`.
  /// Clears the flag **inside** the caller's active `database` so the
  /// upload-ack path's compare and clear share one write transaction,
  /// leaving no window for a concurrent edit to interleave between them
  /// (issue #1081). Unknown record types are a no-op.
  nonisolated func clearNeedsPush(
    recordType: String, ids: [UUID], in database: Database
  ) throws {
    guard
      let clear = referenceNeedsPushClearer(for: recordType, in: database)
        ?? domainNeedsPushClearer(for: recordType, in: database)
    else { return }
    _ = try clear(ids)
  }

  /// Reference-data side of the in-transaction `clearNeedsPush` dispatch.
  nonisolated private func referenceNeedsPushClearer(
    for recordType: String, in database: Database
  ) -> (([UUID]) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { try repos.csvImportProfiles.clearNeedsPushBatchSync($0, in: database) }
    case ImportRuleRow.recordType:
      return { try repos.importRules.clearNeedsPushBatchSync($0, in: database) }
    case CategoryRow.recordType:
      return { try repos.categories.clearNeedsPushBatchSync($0, in: database) }
    case TransferSuggestionRow.recordType:
      return { try repos.transferSuggestions.clearNeedsPushBatchSync($0, in: database) }
    case AccountGroupRow.recordType:
      return { try repos.accountGroups.clearNeedsPushBatchSync($0, in: database) }
    case InsightDismissalRow.recordType:
      return { try repos.insightDismissals.clearNeedsPushBatchSync($0, in: database) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the in-transaction `clearNeedsPush` dispatch.
  nonisolated private func domainNeedsPushClearer(
    for recordType: String, in database: Database
  ) -> (([UUID]) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return { try repos.accounts.clearNeedsPushBatchSync($0, in: database) }
    case EarmarkRow.recordType:
      return { try repos.earmarks.clearNeedsPushBatchSync($0, in: database) }
    case EarmarkBudgetItemRow.recordType:
      return { try repos.earmarkBudgetItems.clearNeedsPushBatchSync($0, in: database) }
    case InvestmentValueRow.recordType:
      return { try repos.investmentValues.clearNeedsPushBatchSync($0, in: database) }
    case TransactionRow.recordType:
      return { try repos.transactions.clearNeedsPushBatchSync($0, in: database) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.clearNeedsPushBatchSync($0, in: database) }
    default:
      return nil
    }
  }

  /// Reference-data side of the `clearNeedsPush` dispatch.
  nonisolated private func referenceNeedsPushClearer(
    for recordType: String
  ) -> (([UUID]) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { try repos.csvImportProfiles.clearNeedsPushBatchSync($0) }
    case ImportRuleRow.recordType:
      return { try repos.importRules.clearNeedsPushBatchSync($0) }
    case CategoryRow.recordType:
      return { try repos.categories.clearNeedsPushBatchSync($0) }
    case TransferSuggestionRow.recordType:
      return { try repos.transferSuggestions.clearNeedsPushBatchSync($0) }
    case AccountGroupRow.recordType:
      return { try repos.accountGroups.clearNeedsPushBatchSync($0) }
    case InsightDismissalRow.recordType:
      return { try repos.insightDismissals.clearNeedsPushBatchSync($0) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `clearNeedsPush` dispatch.
  nonisolated private func domainNeedsPushClearer(
    for recordType: String
  ) -> (([UUID]) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return { try repos.accounts.clearNeedsPushBatchSync($0) }
    case EarmarkRow.recordType:
      return { try repos.earmarks.clearNeedsPushBatchSync($0) }
    case EarmarkBudgetItemRow.recordType:
      return { try repos.earmarkBudgetItems.clearNeedsPushBatchSync($0) }
    case InvestmentValueRow.recordType:
      return { try repos.investmentValues.clearNeedsPushBatchSync($0) }
    case TransactionRow.recordType:
      return { try repos.transactions.clearNeedsPushBatchSync($0) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.clearNeedsPushBatchSync($0) }
    default:
      return nil
    }
  }

  /// Writes a system-fields-only update (change tag, no field values) for
  /// the dirty echoes of `recordType` **inside** the active apply write
  /// `database`, sharing the transaction that read `needs_push`. Skips
  /// records with no UUID component and unknown record types. Dispatch is
  /// split into reference / domain halves for the same complexity reason
  /// as `dirtyIds`.
  nonisolated func applySystemFieldsInTransaction(
    recordType: String, ckRecords: [CKRecord], in database: Database
  ) throws {
    let updates: [(id: UUID, data: Data?)] = ckRecords.compactMap { ckRecord in
      guard let uuid = ckRecord.recordID.uuid else { return nil }
      return (id: uuid, data: ckRecord.encodedSystemFields)
    }
    guard !updates.isEmpty else { return }
    guard
      let setter = referenceInTransactionSystemFieldsSetter(for: recordType)
        ?? domainInTransactionSystemFieldsSetter(for: recordType)
    else {
      Self.batchLogger.warning(
        "applySystemFieldsInTransaction: unknown record type '\(recordType)' — skipping")
      return
    }
    _ = try setter(updates, database)
  }

  /// Reference-data side of the in-transaction system-fields setter lookup.
  nonisolated private func referenceInTransactionSystemFieldsSetter(
    for recordType: String
  ) -> (([(id: UUID, data: Data?)], Database) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { try repos.csvImportProfiles.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case ImportRuleRow.recordType:
      return { try repos.importRules.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case CategoryRow.recordType:
      return { try repos.categories.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case TransferSuggestionRow.recordType:
      return { try repos.transferSuggestions.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case AccountGroupRow.recordType:
      return { try repos.accountGroups.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case InsightDismissalRow.recordType:
      return { try repos.insightDismissals.setEncodedSystemFieldsBatchSync($0, in: $1) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the in-transaction system-fields setter lookup.
  nonisolated private func domainInTransactionSystemFieldsSetter(
    for recordType: String
  ) -> (([(id: UUID, data: Data?)], Database) throws -> Int)? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return { try repos.accounts.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case EarmarkRow.recordType:
      return { try repos.earmarks.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case EarmarkBudgetItemRow.recordType:
      return { try repos.earmarkBudgetItems.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case InvestmentValueRow.recordType:
      return { try repos.investmentValues.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case TransactionRow.recordType:
      return { try repos.transactions.setEncodedSystemFieldsBatchSync($0, in: $1) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.setEncodedSystemFieldsBatchSync($0, in: $1) }
    default:
      return nil
    }
  }
}
