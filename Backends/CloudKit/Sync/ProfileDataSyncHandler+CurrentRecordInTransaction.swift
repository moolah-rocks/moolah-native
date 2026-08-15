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
    let record: CKRecord?
    if let referenceResult = try fetchAndBuildReference(
      recordType: recordType, uuid: id, in: database)
    {
      record = referenceResult
    } else if let domainResult = try fetchAndBuildDomain(
      recordType: recordType, uuid: id, in: database)
    {
      record = domainResult
    } else {
      logger.warning(
        "currentCKRecord: unknown recordType '\(recordType, privacy: .public)' — skipping")
      return nil
    }
    guard let record else { return nil }
    let token = try Self.mutationToken(recordType: recordType, id: id, in: database)
    return SyncMutationToken.attach(token, to: record)
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
      return .some(try repos.categories.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case TaxOwnerRow.recordType:
      return .some(try repos.taxOwners.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case TransferSuggestionRow.recordType:
      return .some(
        try repos.transferSuggestions.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case AccountGroupRow.recordType:
      return .some(try repos.accountGroups.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case InsightDismissalRow.recordType:
      return .some(
        try repos.insightDismissals.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case WalletSyncCheckpointRow.recordType:
      return .some(
        try repos.walletSyncCheckpoints.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case CSVImportProfileRow.recordType:
      return .some(
        try repos.csvImportProfiles.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case ImportRuleRow.recordType:
      return .some(try repos.importRules.fetchRowSync(id: uuid, in: database).map(builtRecord))
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
      return .some(try repos.accounts.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case TransactionRow.recordType:
      return .some(try repos.transactions.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case TransactionLegRow.recordType:
      return .some(
        try repos.transactionLegs.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case EarmarkRow.recordType:
      return .some(try repos.earmarks.fetchRowSync(id: uuid, in: database).map(builtRecord))
    case EarmarkBudgetItemRow.recordType:
      return .some(
        try repos.earmarkBudgetItems.fetchRowSync(id: uuid, in: database).map(builtRecord))
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

  /// Reads the cached server `modificationDate` for each of `ids` of
  /// `recordType`, decoded from the row's stored `encoded_system_fields`
  /// blob **inside** the active apply write `database` (issue #1085). The
  /// clean-path date gate compares these against each incoming echo's date.
  /// Only ids whose row exists AND carries a decodable date appear in the
  /// result; an absent id means "no cached date" → fail-open at the gate.
  ///
  /// Implemented as a point read + decode per id, reusing the existing
  /// `cachedSystemFields` dispatch. The dominant cost is the
  /// `NSKeyedUnarchiver` decode, not the indexed-PK lookups (design §M-1);
  /// a stored, indexed `server_modification_date` column is deliberately
  /// not added unless a benchmark shows the decode is a regression.
  nonisolated func cachedModificationDates(
    recordType: String, ids: [UUID], in database: Database
  ) throws -> [UUID: Date] {
    var result: [UUID: Date] = [:]
    for id in ids {
      guard
        let blob = try cachedSystemFields(recordType: recordType, id: id, in: database),
        let date = CKRecord.modificationDate(fromEncodedSystemFields: blob)
      else { continue }
      result[id] = date
    }
    return result
  }

  /// Reads a row's currently-cached `encodedSystemFields` blob inside the
  /// active `database`, dispatched by record type.
  ///
  /// Returns `Data??`. The outer optional is `.none` ONLY when the record type
  /// is unknown to both dispatch halves — it does NOT indicate row existence.
  /// The per-type lookups use optional chaining
  /// (`fetchRowSync(...)?.encodedSystemFields`), which flattens a missing row
  /// and a present row with a nil blob to the same `.some(.none)`, so the
  /// outer `.some` cannot tell them apart. Callers that only need "is there a
  /// decodable blob" (a `.some(.some)`) is unaffected. The acknowledgement
  /// transaction treats nil as first-upload-or-absent, then uses
  /// `currentCKRecord` before clearing so an absent row safely no-ops
  /// (issues #1081 and #1090).
  nonisolated func cachedSystemFields(
    recordType: String, id: UUID, in database: Database
  ) throws -> Data?? {
    if let reference = try cachedSystemFieldsReference(
      recordType: recordType, id: id, in: database)
    {
      return reference
    }
    return try cachedSystemFieldsDomain(recordType: recordType, id: id, in: database)
  }

  /// Reference-data side of the `cachedSystemFields` dispatch. Outer
  /// `.none` = "not this half's record type". The inner double-optional does
  /// NOT distinguish a missing row from a present row with a nil blob —
  /// optional chaining collapses both to `.some(.none)` (see
  /// `cachedSystemFields`).
  nonisolated private func cachedSystemFieldsReference(
    recordType: String, id: UUID, in database: Database
  ) throws -> (Data??)? {
    let repos = grdbRepositories
    switch recordType {
    case CategoryRow.recordType:
      return try repos.categories.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case TaxOwnerRow.recordType:
      return try repos.taxOwners.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case TransferSuggestionRow.recordType:
      return try repos.transferSuggestions.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case AccountGroupRow.recordType:
      return try repos.accountGroups.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case InsightDismissalRow.recordType:
      return try repos.insightDismissals.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case WalletSyncCheckpointRow.recordType:
      return try repos.walletSyncCheckpoints.fetchRowSync(id: id, in: database)?
        .encodedSystemFields
    case CSVImportProfileRow.recordType:
      return try repos.csvImportProfiles.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case ImportRuleRow.recordType:
      return try repos.importRules.fetchRowSync(id: id, in: database)?.encodedSystemFields
    default:
      return nil
    }
  }

  /// Financial-graph side of the `cachedSystemFields` dispatch.
  nonisolated private func cachedSystemFieldsDomain(
    recordType: String, id: UUID, in database: Database
  ) throws -> Data?? {
    let repos = grdbRepositories
    switch recordType {
    case AccountRow.recordType:
      return try repos.accounts.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case TransactionRow.recordType:
      return try repos.transactions.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case TransactionLegRow.recordType:
      return try repos.transactionLegs.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case EarmarkRow.recordType:
      return try repos.earmarks.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case EarmarkBudgetItemRow.recordType:
      return try repos.earmarkBudgetItems.fetchRowSync(id: id, in: database)?.encodedSystemFields
    default:
      return nil
    }
  }
}
