@preconcurrency import CloudKit
import Foundation

extension ProfileDataSyncHandler {
  // MARK: - Batch Record Lookup

  /// Looks up records grouped by their CKRecord recordType. Each group
  /// runs one batch fetch over its own GRDB repo so two different record
  /// types that happen to share a UUID don't collide in the result.
  /// Returns `[recordType: [UUID: CKRecord]]`.
  func buildBatchRecordLookup(
    byRecordType groups: [String: Set<UUID>]
  ) -> [String: [UUID: CKRecord]] {
    var result: [String: [UUID: CKRecord]] = [:]
    for (recordType, uuids) in groups {
      guard !uuids.isEmpty else { continue }
      result[recordType] = batchFetchByType(recordType: recordType, uuids: uuids)
    }
    return result
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
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    if let recordType = recordID.prefixedRecordType, let uuid = recordID.uuid {
      if recordType == InstrumentRow.recordType {
        return trapInstrumentOnPerProfileZone(detail: "prefixed UUID upload")
      }
      return fetchAndBuild(recordType: recordType, uuid: uuid)
    }
    return trapInstrumentOnPerProfileZone(
      detail: "string-keyed recordName \(recordID.recordName)")
  }

  private func trapInstrumentOnPerProfileZone(detail: String) -> CKRecord? {
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
      return nil
    #endif
  }

  // MARK: - Per-Type Dispatch

  /// Single-record dispatcher. Returns nil for unknown recordType
  /// strings. The lookup is split between a reference-data half and a
  /// financial-graph half (each returning a double-optional: outer
  /// `.none` = "not this half's record type", inner `nil` = "handled,
  /// no such row") so neither switch breaches the cyclomatic-complexity
  /// ceiling — same shape as `saveHandler` in `+GRDBDispatch`.
  private func fetchAndBuild(recordType: String, uuid: UUID) -> CKRecord? {
    if let referenceResult = fetchAndBuildReference(recordType: recordType, uuid: uuid) {
      return referenceResult
    }
    if let domainResult = fetchAndBuildDomain(recordType: recordType, uuid: uuid) {
      return domainResult
    }
    logger.warning(
      "Unknown recordType '\(recordType, privacy: .public)' in prefixed recordID — skipping"
    )
    return nil
  }

  /// Reference-data side of the `fetchAndBuild` dispatch.
  private func fetchAndBuildReference(
    recordType: String, uuid: UUID
  ) -> CKRecord?? {
    switch recordType {
    case CategoryRow.recordType:
      return fetchCategoryRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case TransferSuggestionRow.recordType:
      return fetchTransferSuggestionRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case AccountGroupRow.recordType:
      return fetchAccountGroupRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case CSVImportProfileRow.recordType:
      return fetchCSVImportProfileRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case ImportRuleRow.recordType:
      return fetchImportRuleRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `fetchAndBuild` dispatch.
  private func fetchAndBuildDomain(
    recordType: String, uuid: UUID
  ) -> CKRecord?? {
    switch recordType {
    case AccountRow.recordType:
      return fetchAccountRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case TransactionRow.recordType:
      return fetchTransactionRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case TransactionLegRow.recordType:
      return fetchTransactionLegRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case EarmarkRow.recordType:
      return fetchEarmarkRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case EarmarkBudgetItemRow.recordType:
      return fetchEarmarkBudgetItemRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case InvestmentValueRow.recordType:
      return fetchInvestmentValueRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    default:
      return nil
    }
  }

  /// Batch-fetch dispatcher. One batch fetch per type, mapped into
  /// `[UUID: CKRecord]` via `buildCKRecord`. Split into a reference-data
  /// half and a financial-graph half (each returning `nil` for "not this
  /// half's record type") so neither switch breaches the
  /// cyclomatic-complexity ceiling — same shape as `saveHandler` in
  /// `+GRDBDispatch`.
  private func batchFetchByType(
    recordType: String, uuids: Set<UUID>
  ) -> [UUID: CKRecord] {
    let ids = Array(uuids)
    guard
      let fetch =
        batchFetchReference(for: recordType, ids: ids)
        ?? batchFetchDomain(for: recordType, ids: ids)
    else {
      logger.warning(
        "Unknown recordType '\(recordType, privacy: .public)' in batch lookup — skipping"
      )
      return [:]
    }
    return fetch()
  }

  /// Reference-data side of the `batchFetchByType` dispatch. Returns the
  /// batch-fetch thunk, or `nil` when `recordType` is not reference data.
  private func batchFetchReference(
    for recordType: String, ids: [UUID]
  ) -> (() -> [UUID: CKRecord])? {
    switch recordType {
    case CategoryRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch { try self.grdbRepositories.categories.fetchRowsSync(ids: ids) })
      }
    case TransferSuggestionRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch {
            try self.grdbRepositories.transferSuggestions.fetchRowsSync(ids: ids)
          })
      }
    case AccountGroupRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch {
            try self.grdbRepositories.accountGroups.fetchRowsSync(ids: ids)
          })
      }
    case CSVImportProfileRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch {
            try self.grdbRepositories.csvImportProfiles.fetchRowsSync(ids: ids)
          })
      }
    case ImportRuleRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch { try self.grdbRepositories.importRules.fetchRowsSync(ids: ids) })
      }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `batchFetchByType` dispatch. Returns
  /// the batch-fetch thunk, or `nil` when `recordType` is not a
  /// financial-graph row.
  private func batchFetchDomain(
    for recordType: String, ids: [UUID]
  ) -> (() -> [UUID: CKRecord])? {
    switch recordType {
    case AccountRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch { try self.grdbRepositories.accounts.fetchRowsSync(ids: ids) })
      }
    case TransactionRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch { try self.grdbRepositories.transactions.fetchRowsSync(ids: ids) })
      }
    case TransactionLegRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch {
            try self.grdbRepositories.transactionLegs.fetchRowsSync(ids: ids)
          })
      }
    case EarmarkRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch { try self.grdbRepositories.earmarks.fetchRowsSync(ids: ids) })
      }
    case EarmarkBudgetItemRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch {
            try self.grdbRepositories.earmarkBudgetItems.fetchRowsSync(ids: ids)
          })
      }
    case InvestmentValueRow.recordType:
      return {
        self.mapBuiltRows(
          self.fetchRowsBatch {
            try self.grdbRepositories.investmentValues.fetchRowsSync(ids: ids)
          })
      }
    default:
      return nil
    }
  }

  /// Reduces a fetched batch of GRDB rows into `[UUID: CKRecord]` keyed
  /// by the row's own `id`, with each value built via
  /// `buildCKRecord(from:encodedSystemFields:)`.
  private func mapBuiltRows<T>(_ rows: [T]) -> [UUID: CKRecord]
  where T: IdentifiableRecord & CloudKitRecordConvertible & ValueTypeSystemFieldsReadable {
    var built: [UUID: CKRecord] = [:]
    built.reserveCapacity(rows.count)
    for row in rows {
      built[row.id] = buildCKRecord(
        from: row, encodedSystemFields: row.encodedSystemFields)
    }
    return built
  }

  /// Common error-handling wrapper for the batch-fetch closures used in
  /// `batchFetchByType`. Logs at error level on throw and returns an
  /// empty array (mirroring the SwiftData path's `fetchOrLog`
  /// best-effort semantics).
  private func fetchRowsBatch<T>(_ work: () throws -> [T]) -> [T] {
    do {
      return try work()
    } catch {
      logger.error(
        """
        GRDB batch fetch failed: \(error.localizedDescription, privacy: .public)
        """)
      return []
    }
  }

  // MARK: - Per-Row Lookups

  private func fetchAccountRow(id: UUID) -> AccountRow? {
    fetchRowOrLog { try grdbRepositories.accounts.fetchRowSync(id: id) }
  }

  private func fetchTransactionRow(id: UUID) -> TransactionRow? {
    fetchRowOrLog { try grdbRepositories.transactions.fetchRowSync(id: id) }
  }

  private func fetchTransactionLegRow(id: UUID) -> TransactionLegRow? {
    fetchRowOrLog { try grdbRepositories.transactionLegs.fetchRowSync(id: id) }
  }

  private func fetchCategoryRow(id: UUID) -> CategoryRow? {
    fetchRowOrLog { try grdbRepositories.categories.fetchRowSync(id: id) }
  }

  private func fetchTransferSuggestionRow(id: UUID) -> TransferSuggestionRow? {
    fetchRowOrLog { try grdbRepositories.transferSuggestions.fetchRowSync(id: id) }
  }

  private func fetchAccountGroupRow(id: UUID) -> AccountGroupRow? {
    fetchRowOrLog { try grdbRepositories.accountGroups.fetchRowSync(id: id) }
  }

  private func fetchEarmarkRow(id: UUID) -> EarmarkRow? {
    fetchRowOrLog { try grdbRepositories.earmarks.fetchRowSync(id: id) }
  }

  private func fetchEarmarkBudgetItemRow(id: UUID) -> EarmarkBudgetItemRow? {
    fetchRowOrLog { try grdbRepositories.earmarkBudgetItems.fetchRowSync(id: id) }
  }

  private func fetchInvestmentValueRow(id: UUID) -> InvestmentValueRow? {
    fetchRowOrLog { try grdbRepositories.investmentValues.fetchRowSync(id: id) }
  }

  private func fetchCSVImportProfileRow(id: UUID) -> CSVImportProfileRow? {
    fetchRowOrLog { try grdbRepositories.csvImportProfiles.fetchRowSync(id: id) }
  }

  private func fetchImportRuleRow(id: UUID) -> ImportRuleRow? {
    fetchRowOrLog { try grdbRepositories.importRules.fetchRowSync(id: id) }
  }

  /// Common error-handling wrapper for the per-row fetch closures used
  /// above. Logs at error level on throw and returns `nil`.
  private func fetchRowOrLog<T>(_ work: () throws -> T?) -> T? {
    do {
      return try work()
    } catch {
      logger.error(
        """
        GRDB fetch failed: \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }
}
