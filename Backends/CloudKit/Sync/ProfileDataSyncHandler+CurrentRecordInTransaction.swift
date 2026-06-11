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

  /// Reads each saved record's currently-cached `encodedSystemFields` keyed by
  /// `<recordType>|<uuid>`, so `handleSentRecordZoneChanges` can snapshot the
  /// pre-ack cache before `updateSystemFieldsForSaved` overwrites it. Records
  /// each id whose `cachedSystemFields` lookup resolves, storing its nullable
  /// cached blob; the ack-clear then treats a nil blob conservatively (no
  /// clear), so an id whose row is absent or never round-tripped is handled
  /// the same safe way. A read error is logged and the whole batch is omitted
  /// (issue #1081 follow-up).
  nonisolated func preAckCachedSystemFields(
    _ savedRecords: [CKRecord]
  ) -> [String: Data?] {
    var result: [String: Data?] = [:]
    do {
      try grdbRepositories.database.read { database in
        for saved in savedRecords {
          guard let uuid = saved.recordID.uuid else { continue }
          if let blob = try self.cachedSystemFields(
            recordType: saved.recordType, id: uuid, in: database)
          {
            result[saved.recordID.systemFieldsKey] = blob
          }
        }
      }
    } catch {
      logger.error(
        """
        preAckCachedSystemFields read failed: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
    return result
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
  /// decodable blob" (a `.some(.some)`) — `cachedModificationDates`,
  /// `preAckCachedSystemFields` — are unaffected; a caller that must
  /// distinguish a genuinely missing row should use `currentCKRecord`
  /// (issue #1090).
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
    case TransferSuggestionRow.recordType:
      return try repos.transferSuggestions.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case AccountGroupRow.recordType:
      return try repos.accountGroups.fetchRowSync(id: id, in: database)?.encodedSystemFields
    case InsightDismissalRow.recordType:
      return try repos.insightDismissals.fetchRowSync(id: id, in: database)?.encodedSystemFields
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
    case InvestmentValueRow.recordType:
      return try repos.investmentValues.fetchRowSync(id: id, in: database)?.encodedSystemFields
    default:
      return nil
    }
  }
}
