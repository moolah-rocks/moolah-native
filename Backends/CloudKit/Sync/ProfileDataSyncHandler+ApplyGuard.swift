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
