@preconcurrency import CloudKit
import Foundation
import GRDB

/// Thrown by the record-lookup dispatch when a prefixed recordID names a
/// record type this build does not handle. Surfaced (not swallowed) so the
/// send path classifies it as `failed` and keeps the change pending rather
/// than deleting a record of a type a newer build introduced.
private struct UnknownRecordTypeError: Error {
  let recordType: String
}

extension ProfileDataSyncHandler {
  // MARK: - Batch Record Lookup

  /// Looks up records grouped by their CKRecord recordType. Each group
  /// runs one batch fetch over its own GRDB repo so two different record
  /// types that happen to share a UUID don't collide in the result.
  /// Returns a per-type `BatchLookupOutcome` so the caller can tell a
  /// genuinely-absent id (query succeeded) from a failed query (issue #1087).
  func buildBatchRecordLookup(
    byRecordType groups: [String: Set<UUID>]
  ) -> [String: BatchLookupOutcome] {
    var result: [String: BatchLookupOutcome] = [:]
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
  func recordToSave(for recordID: CKRecord.ID) -> RecordLookupOutcome {
    if let recordType = recordID.prefixedRecordType, let uuid = recordID.uuid {
      if recordType == InstrumentRow.recordType {
        return trapInstrumentOnPerProfileZone(detail: "prefixed UUID upload")
      }
      do {
        if let record = try fetchAndBuild(recordType: recordType, uuid: uuid) {
          return .found(record)
        }
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
  private func trapInstrumentOnPerProfileZone(detail: String) -> RecordLookupOutcome {
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

  // MARK: - Current Record for Ack Comparison

  /// Builds the `CKRecord` for the current local row of `recordType` /
  /// `id`, or `nil` if no such row exists or the type is unknown. Used by
  /// the upload-ack path to compare the current row's user fields against
  /// the version that was just confirmed saved: if they match, the local
  /// edit is confirmed and `needs_push` can be cleared; if they differ, a
  /// newer edit is pending and the flag stays set (issue #1081). Reuses
  /// the same per-type `fetchAndBuild` dispatch as the upload path.
  func currentCKRecord(recordType: String, id: UUID) -> CKRecord? {
    // Ack comparison treats both "absent" and "lookup error" as "no current
    // record" (→ leave `needs_push` set), so swallowing the throw to `nil`
    // is correct here — unlike the upload path, which must distinguish them.
    try? fetchAndBuild(recordType: recordType, uuid: id)
  }

  // The in-transaction counterpart `currentCKRecord(recordType:id:in:)`
  // lives in `ProfileDataSyncHandler+CurrentRecordInTransaction.swift`.

  // MARK: - Per-Type Dispatch

  /// Single-record dispatcher. Returns `nil` for a handled type whose row is
  /// absent, and THROWS `UnknownRecordTypeError` for a record type this build
  /// does not handle (so the caller keeps the change pending rather than
  /// deleting it). The lookup is split between a reference-data half and a
  /// financial-graph half (each returns a double-optional: outer `.none` =
  /// "not this half's record type", `.some(inner)` = "handled", inner `nil` =
  /// "no such row") so neither switch breaches the cyclomatic-complexity
  /// ceiling — same shape as `saveHandler` in `+GRDBDispatch`.
  private func fetchAndBuild(recordType: String, uuid: UUID) throws -> CKRecord? {
    if let referenceResult = try fetchAndBuildReference(recordType: recordType, uuid: uuid) {
      return referenceResult
    }
    if let domainResult = try fetchAndBuildDomain(recordType: recordType, uuid: uuid) {
      return domainResult
    }
    logger.warning(
      "Unknown recordType '\(recordType, privacy: .public)' in prefixed recordID — keeping pending"
    )
    throw UnknownRecordTypeError(recordType: recordType)
  }

  /// Wraps a fetched row in the dispatch's `CKRecord??` "handled" shape:
  /// `.some(record)` for a present row, `.some(nil)` for an absent one. The
  /// explicit `.some` is load-bearing — returning a bare `CKRecord?` would
  /// flatten an absent row to the outer `.none` ("not handled"), which the
  /// caller would then misread as an unknown type.
  private func built<Row>(_ row: Row?) -> CKRecord??
  where Row: CloudKitRecordConvertible & ValueTypeSystemFieldsReadable {
    .some(row.map { buildCKRecord(from: $0, encodedSystemFields: $0.encodedSystemFields) })
  }

  /// Reference-data side of the `fetchAndBuild` dispatch. A thrown GRDB error
  /// propagates to `recordToSave` (→ `.failed`); a `.some(nil)` is a
  /// genuinely-absent row (→ `.absent`); the `default` `.none` means "not my
  /// half".
  private func fetchAndBuildReference(
    recordType: String, uuid: UUID
  ) throws -> CKRecord?? {
    switch recordType {
    case CategoryRow.recordType: return built(try fetchCategoryRow(id: uuid))
    case TransferSuggestionRow.recordType: return built(try fetchTransferSuggestionRow(id: uuid))
    case AccountGroupRow.recordType: return built(try fetchAccountGroupRow(id: uuid))
    case InsightDismissalRow.recordType: return built(try fetchInsightDismissalRow(id: uuid))
    case WalletSyncCheckpointRow.recordType:
      return built(try fetchWalletSyncCheckpointRow(id: uuid))
    case CSVImportProfileRow.recordType: return built(try fetchCSVImportProfileRow(id: uuid))
    case ImportRuleRow.recordType: return built(try fetchImportRuleRow(id: uuid))
    default: return nil
    }
  }

  /// Financial-graph side of the `fetchAndBuild` dispatch.
  private func fetchAndBuildDomain(
    recordType: String, uuid: UUID
  ) throws -> CKRecord?? {
    switch recordType {
    case AccountRow.recordType: return built(try fetchAccountRow(id: uuid))
    case TransactionRow.recordType: return built(try fetchTransactionRow(id: uuid))
    case TransactionLegRow.recordType: return built(try fetchTransactionLegRow(id: uuid))
    case EarmarkRow.recordType: return built(try fetchEarmarkRow(id: uuid))
    case EarmarkBudgetItemRow.recordType: return built(try fetchEarmarkBudgetItemRow(id: uuid))
    case InvestmentValueRow.recordType: return built(try fetchInvestmentValueRow(id: uuid))
    default: return nil
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
  ) -> BatchLookupOutcome {
    let ids = Array(uuids)
    guard
      let fetch =
        batchFetchReference(for: recordType, ids: ids)
        ?? batchFetchDomain(for: recordType, ids: ids)
    else {
      // Unhandled type (unreachable in practice): keep every id pending
      // rather than deleting a record of a type a newer build introduced.
      logger.warning(
        "Unknown recordType '\(recordType, privacy: .public)' in batch lookup — keeping pending"
      )
      return .failed
    }
    do {
      return .succeeded(try fetch())
    } catch {
      logger.error(
        """
        GRDB batch fetch failed for \(recordType, privacy: .public): \
        \(error.localizedDescription, privacy: .public) — keeping all \
        \(ids.count, privacy: .public) pending
        """)
      return .failed
    }
  }

  /// Reference-data side of the `batchFetchByType` dispatch. Returns the
  /// throwing batch-fetch thunk, or `nil` when `recordType` is not reference
  /// data. A thrown GRDB error propagates so the caller classifies the whole
  /// group as `failed` (issue #1087).
  private func batchFetchReference(
    for recordType: String, ids: [UUID]
  ) -> (() throws -> [UUID: CKRecord])? {
    switch recordType {
    case CategoryRow.recordType:
      return { self.mapBuiltRows(try self.grdbRepositories.categories.fetchRowsSync(ids: ids)) }
    case TransferSuggestionRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.transferSuggestions.fetchRowsSync(ids: ids))
      }
    case AccountGroupRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.accountGroups.fetchRowsSync(ids: ids))
      }
    case InsightDismissalRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.insightDismissals.fetchRowsSync(ids: ids))
      }
    case WalletSyncCheckpointRow.recordType:
      return {
        self.mapBuiltRows(
          try self.grdbRepositories.walletSyncCheckpoints.fetchRowsSync(ids: ids))
      }
    case CSVImportProfileRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.csvImportProfiles.fetchRowsSync(ids: ids))
      }
    case ImportRuleRow.recordType:
      return { self.mapBuiltRows(try self.grdbRepositories.importRules.fetchRowsSync(ids: ids)) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `batchFetchByType` dispatch. Returns
  /// the throwing batch-fetch thunk, or `nil` when `recordType` is not a
  /// financial-graph row.
  private func batchFetchDomain(
    for recordType: String, ids: [UUID]
  ) -> (() throws -> [UUID: CKRecord])? {
    switch recordType {
    case AccountRow.recordType:
      return { self.mapBuiltRows(try self.grdbRepositories.accounts.fetchRowsSync(ids: ids)) }
    case TransactionRow.recordType:
      return { self.mapBuiltRows(try self.grdbRepositories.transactions.fetchRowsSync(ids: ids)) }
    case TransactionLegRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.transactionLegs.fetchRowsSync(ids: ids))
      }
    case EarmarkRow.recordType:
      return { self.mapBuiltRows(try self.grdbRepositories.earmarks.fetchRowsSync(ids: ids)) }
    case EarmarkBudgetItemRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.earmarkBudgetItems.fetchRowsSync(ids: ids))
      }
    case InvestmentValueRow.recordType:
      return {
        self.mapBuiltRows(try self.grdbRepositories.investmentValues.fetchRowsSync(ids: ids))
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

  // MARK: - Per-Row Lookups
  //
  // These propagate a GRDB error (rather than swallowing it to `nil`) so the
  // upload path can tell a genuinely-absent row from a failed read (issue
  // #1087). `nil` means "row absent"; a throw means "lookup failed".

  private func fetchAccountRow(id: UUID) throws -> AccountRow? {
    try grdbRepositories.accounts.fetchRowSync(id: id)
  }

  private func fetchTransactionRow(id: UUID) throws -> TransactionRow? {
    try grdbRepositories.transactions.fetchRowSync(id: id)
  }

  private func fetchTransactionLegRow(id: UUID) throws -> TransactionLegRow? {
    try grdbRepositories.transactionLegs.fetchRowSync(id: id)
  }

  private func fetchCategoryRow(id: UUID) throws -> CategoryRow? {
    try grdbRepositories.categories.fetchRowSync(id: id)
  }

  private func fetchTransferSuggestionRow(id: UUID) throws -> TransferSuggestionRow? {
    try grdbRepositories.transferSuggestions.fetchRowSync(id: id)
  }

  private func fetchAccountGroupRow(id: UUID) throws -> AccountGroupRow? {
    try grdbRepositories.accountGroups.fetchRowSync(id: id)
  }

  private func fetchInsightDismissalRow(id: UUID) throws -> InsightDismissalRow? {
    try grdbRepositories.insightDismissals.fetchRowSync(id: id)
  }

  private func fetchWalletSyncCheckpointRow(id: UUID) throws -> WalletSyncCheckpointRow? {
    try grdbRepositories.walletSyncCheckpoints.fetchRowSync(id: id)
  }

  private func fetchEarmarkRow(id: UUID) throws -> EarmarkRow? {
    try grdbRepositories.earmarks.fetchRowSync(id: id)
  }

  private func fetchEarmarkBudgetItemRow(id: UUID) throws -> EarmarkBudgetItemRow? {
    try grdbRepositories.earmarkBudgetItems.fetchRowSync(id: id)
  }

  private func fetchInvestmentValueRow(id: UUID) throws -> InvestmentValueRow? {
    try grdbRepositories.investmentValues.fetchRowSync(id: id)
  }

  private func fetchCSVImportProfileRow(id: UUID) throws -> CSVImportProfileRow? {
    try grdbRepositories.csvImportProfiles.fetchRowSync(id: id)
  }

  private func fetchImportRuleRow(id: UUID) throws -> ImportRuleRow? {
    try grdbRepositories.importRules.fetchRowSync(id: id)
  }
}
