@preconcurrency import CloudKit
import Foundation
import GRDB

private enum BatchFetchDispatch {
  case rows([UUID: CKRecord])
  case unhandled
}

extension ProfileDataSyncHandler {
  // MARK: - Batch Record Lookup

  /// Looks up records grouped by their CKRecord recordType. Each group
  /// runs one batch fetch over its own GRDB repo so two different record
  /// types that happen to share a UUID don't collide in the result.
  /// Returns a per-type `BatchLookupOutcome` so the caller can tell a
  /// genuinely-absent id (query succeeded) from a failed query (issue #1087).
  nonisolated func buildBatchRecordLookup(
    byRecordType groups: [String: Set<UUID>]
  ) -> [String: BatchLookupOutcome] {
    do {
      return try grdbRepositories.database.read { database in
        var result: [String: BatchLookupOutcome] = [:]
        for (recordType, uuids) in groups {
          guard !uuids.isEmpty else { continue }
          do {
            result[recordType] = try batchFetchByType(
              recordType: recordType, uuids: uuids, in: database)
          } catch {
            logger.error(
              "GRDB batch lookup failed for \(recordType, privacy: .public): \(error, privacy: .public)"
            )
            result[recordType] = .failed
          }
        }
        return result
      }
    } catch {
      logger.error("GRDB batch lookup failed: \(error, privacy: .public)")
      return Dictionary(uniqueKeysWithValues: groups.keys.map { ($0, .failed) })
    }
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a single record by `CKRecord.ID` and builds the `CKRecord`
  /// for upload. Dispatches by the recordType prefix encoded in the
  /// recordName (`<recordType>|<UUID>`); unprefixed recordNames are
  /// treated as string IDs and routed to the Instrument lookup.
  ///
  /// **DEBUG trap for `InstrumentRecord` on per-profile zones.**
  /// Every `InstrumentRecord` upload routes through the shared registry
  /// on the profile-index zone. A pending change for `InstrumentRecord`
  /// reaching this per-profile handler is a programmer error: a callsite
  /// queued it on the wrong zone. The DEBUG `preconditionFailure` fails
  /// the test suite immediately so the regression cannot land. Release
  /// builds log the violation and return `nil`, letting CKSyncEngine
  /// drop the change.
  ///
  /// String-keyed recordIDs (the bare `recordName` form used for
  /// `InstrumentRecord`) are also caught here: they have no legitimate
  /// per-profile path, so the same trap applies symmetrically.
  nonisolated func recordToSave(for recordID: CKRecord.ID) -> RecordLookupOutcome {
    if let recordType = recordID.prefixedRecordType, let uuid = recordID.uuid {
      if recordType == InstrumentRow.recordType {
        return trapInstrumentOnPerProfileZone(detail: "prefixed UUID upload")
      }
      guard Self.syncTableByRecordType[recordType] != nil else {
        logger.warning(
          "Unknown recordType '\(recordType, privacy: .public)' in prefixed recordID — keeping pending"
        )
        return .failed
      }
      do {
        let record = try grdbRepositories.database.read { database in
          try currentCKRecord(recordType: recordType, id: uuid, in: database)
        }
        if let record { return .found(record) }
        return .absent
      } catch {
        logger.error(
          """
          GRDB lookup failed for \(recordType, privacy: .public) \
          \(uuid, privacy: .public): \(error.localizedDescription, privacy: .public) \
          — keeping pending
          """)
        return .failed
      }
    }
    return trapInstrumentOnPerProfileZone(
      detail: "string-keyed recordName \(recordID.recordName)")
  }

  /// An `InstrumentRecord` reaching the per-profile handler is a routing bug
  /// (instruments live on the shared profile-index registry). DEBUG traps so
  /// the regression can't land; release keeps the change pending (`failed`)
  /// rather than queueing a spurious server deletion — the startup
  /// `purgeLegacyInstrumentPendingChanges` clears any residual entry.
  nonisolated private func trapInstrumentOnPerProfileZone(
    detail: String
  ) -> RecordLookupOutcome {
    let message =
      """
      InstrumentRecord upload routed to per-profile zone \
      \(self.zoneID.zoneName) (\(detail)) — every InstrumentRecord \
      write must go through the shared registry on the profile-index \
      zone. Audit the callsite that produced this pending change.
      """
    #if DEBUG
      preconditionFailure(message)
    #else
      logger.error("\(message, privacy: .public)")
      return .failed
    #endif
  }

  /// Batch-fetch dispatcher. One batch fetch per type, mapped into
  /// `[UUID: CKRecord]` via `buildCKRecord`. Split into a reference-data
  /// half and a financial-graph half (each returning `.unhandled` for a type
  /// owned by the other half) so neither switch breaches the
  /// cyclomatic-complexity ceiling — same shape as `saveHandler` in
  /// `+GRDBDispatch`.
  nonisolated private func batchFetchByType(
    recordType: String, uuids: Set<UUID>, in database: Database
  ) throws -> BatchLookupOutcome {
    let ids = Array(uuids)
    switch try batchFetchReference(for: recordType, ids: ids, in: database) {
    case .rows(let rows):
      return .succeeded(rows)
    case .unhandled:
      break
    }
    switch try batchFetchDomain(for: recordType, ids: ids, in: database) {
    case .rows(let rows):
      return .succeeded(rows)
    case .unhandled:
      // Unhandled type (unreachable in practice): keep every id pending
      // rather than deleting a record of a type a newer build introduced.
      logger.warning(
        "Unknown recordType '\(recordType, privacy: .public)' in batch lookup — keeping pending"
      )
      return .failed
    }
  }

  /// Reference-data side of the `batchFetchByType` dispatch. A thrown GRDB
  /// error propagates so the caller classifies the whole group as `failed`;
  /// `.unhandled` routes the type to the financial-graph dispatcher.
  nonisolated private func batchFetchReference(
    for recordType: String, ids: [UUID], in database: Database
  ) throws -> BatchFetchDispatch {
    switch recordType {
    case CategoryRow.recordType:
      return .rows(
        try batchBuiltRows(CategoryRow.self, recordType: recordType, ids: ids, in: database))
    case TaxOwnerRow.recordType:
      return .rows(
        try batchBuiltRows(TaxOwnerRow.self, recordType: recordType, ids: ids, in: database))
    case TransferSuggestionRow.recordType:
      return .rows(
        try batchBuiltRows(
          TransferSuggestionRow.self, recordType: recordType, ids: ids, in: database))
    case AccountGroupRow.recordType:
      return .rows(
        try batchBuiltRows(
          AccountGroupRow.self, recordType: recordType, ids: ids, in: database))
    case InsightDismissalRow.recordType:
      return .rows(
        try batchBuiltRows(
          InsightDismissalRow.self, recordType: recordType, ids: ids, in: database))
    case WalletSyncCheckpointRow.recordType:
      return .rows(
        try batchBuiltRows(
          WalletSyncCheckpointRow.self, recordType: recordType, ids: ids, in: database))
    case CSVImportProfileRow.recordType:
      return .rows(
        try batchBuiltRows(
          CSVImportProfileRow.self, recordType: recordType, ids: ids, in: database))
    case ImportRuleRow.recordType:
      return .rows(
        try batchBuiltRows(
          ImportRuleRow.self, recordType: recordType, ids: ids, in: database))
    default:
      return .unhandled
    }
  }

  /// Financial-graph side of the `batchFetchByType` dispatch. Returns
  /// `.unhandled` when `recordType` is not a financial-graph row.
  nonisolated private func batchFetchDomain(
    for recordType: String, ids: [UUID], in database: Database
  ) throws -> BatchFetchDispatch {
    switch recordType {
    case AccountRow.recordType:
      return .rows(
        try batchBuiltRows(AccountRow.self, recordType: recordType, ids: ids, in: database))
    case TransactionRow.recordType:
      return .rows(
        try batchBuiltRows(
          TransactionRow.self, recordType: recordType, ids: ids, in: database))
    case TransactionLegRow.recordType:
      return .rows(
        try batchBuiltRows(
          TransactionLegRow.self, recordType: recordType, ids: ids, in: database))
    case EarmarkRow.recordType:
      return .rows(
        try batchBuiltRows(EarmarkRow.self, recordType: recordType, ids: ids, in: database))
    case EarmarkBudgetItemRow.recordType:
      return .rows(
        try batchBuiltRows(
          EarmarkBudgetItemRow.self, recordType: recordType, ids: ids, in: database))
    default:
      return .unhandled
    }
  }

  nonisolated private func batchBuiltRows<T>(
    _ type: T.Type, recordType: String, ids: [UUID], in database: Database
  ) throws -> [UUID: CKRecord]
  where
    T: FetchableRecord & TableRecord & IdentifiableRecord & CloudKitRecordConvertible
      & ValueTypeSystemFieldsReadable
  {
    let rows = try T.fetchAll(database, keys: ids)
    let tokens = try Self.mutationTokens(recordType: recordType, ids: ids, in: database)
    return Dictionary(
      uniqueKeysWithValues: rows.map { row in
        let record = buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
        return (row.id, SyncMutationToken.attach(tokens[row.id], to: record))
      })
  }
}
