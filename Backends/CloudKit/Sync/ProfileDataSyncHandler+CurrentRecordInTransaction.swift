@preconcurrency import CloudKit
import Foundation
import GRDB

// In-transaction current-row → CKRecord builder for the upload-ack
// compare-and-clear path (issue #1081). Split out of
// `ProfileDataSyncHandler+RecordLookup.swift` to keep that file under the
// 400-line limit.

extension ProfileDataSyncHandler {
  /// In-transaction counterpart to `currentCKRecord(recordType:id:)`.
  /// Reads the current row **inside** the caller's active `database` so
  /// the upload-ack path can re-fetch, compare, and clear `needs_push`
  /// without releasing the write transaction — leaving no window for a
  /// concurrent edit to commit between the compare and the clear (issue
  /// #1081). Returns `nil` for a missing row or an unknown record type;
  /// errors propagate so the surrounding transaction rolls back.
  nonisolated func currentCKRecord(
    recordType: String, id: UUID, in database: Database
  ) throws -> CKRecord? {
    if let referenceResult = try fetchAndBuildReference(
      recordType: recordType, uuid: id, in: database)
    {
      return referenceResult
    }
    if let domainResult = try fetchAndBuildDomain(
      recordType: recordType, uuid: id, in: database)
    {
      return domainResult
    }
    logger.warning(
      "currentCKRecord: unknown recordType '\(recordType, privacy: .public)' — skipping")
    return nil
  }

  /// Reference-data side of the in-transaction `currentCKRecord` dispatch.
  /// Outer `.none` = "not this half's record type"; inner `nil` =
  /// "handled, no such row".
  nonisolated private func fetchAndBuildReference(
    recordType: String, uuid: UUID, in database: Database
  ) throws -> CKRecord?? {
    let repos = grdbRepositories
    switch recordType {
    case CategoryRow.recordType:
      return try repos.categories.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case TransferSuggestionRow.recordType:
      return try repos.transferSuggestions.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case AccountGroupRow.recordType:
      return try repos.accountGroups.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case InsightDismissalRow.recordType:
      return try repos.insightDismissals.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case CSVImportProfileRow.recordType:
      return try repos.csvImportProfiles.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case ImportRuleRow.recordType:
      return try repos.importRules.fetchRowSync(id: uuid, in: database).map(builtRecord)
    default:
      return nil
    }
  }

  /// Financial-graph side of the in-transaction `currentCKRecord` dispatch.
  nonisolated private func fetchAndBuildDomain(
    recordType: String, uuid: UUID, in database: Database
  ) throws -> CKRecord?? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return try repos.accounts.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case TransactionRow.recordType:
      return try repos.transactions.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case TransactionLegRow.recordType:
      return try repos.transactionLegs.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case EarmarkRow.recordType:
      return try repos.earmarks.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case EarmarkBudgetItemRow.recordType:
      return try repos.earmarkBudgetItems.fetchRowSync(id: uuid, in: database).map(builtRecord)
    case InvestmentValueRow.recordType:
      return try repos.investmentValues.fetchRowSync(id: uuid, in: database).map(builtRecord)
    default:
      return nil
    }
  }

  /// Builds the upload `CKRecord` for a fetched row, carrying its cached
  /// system fields. Shared by both in-transaction dispatch halves.
  nonisolated private func builtRecord<T>(_ row: T) -> CKRecord
  where T: CloudKitRecordConvertible & ValueTypeSystemFieldsReadable {
    buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
  }
}
