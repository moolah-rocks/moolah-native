@preconcurrency import CloudKit
import Foundation
import GRDB

extension ProfileDataSyncHandler {
  // MARK: - Per-Record-Type Save Helpers

  /// Inputs to the per-record-type save helpers. Bundling them keeps
  /// each helper signature compact; the underlying `mapRows` dispatch
  /// uses the typed `Row` argument to recover the CKRecord decoder and
  /// the per-row id key.
  struct GRDBBatchSaveContext {
    let ckRecords: [CKRecord]
    let systemFields: [String: Data]
    let site: String
  }

  nonisolated func applyBatchSaveCSVImportProfile(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[CSVImportProfile]")
    let rows = mapRows(
      context: context,
      fieldValues: CSVImportProfileRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.csvImportProfiles.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveImportRule(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[ImportRule]")
    let rows = mapRows(
      context: context,
      fieldValues: ImportRuleRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.importRules.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  /// **Decommissioned per-profile-zone apply path.** Every
  /// `InstrumentRecord` save lives on the profile-index zone (the
  /// shared registry). A delivery on a per-profile zone is straggler
  /// state from a peer device on an older build; there is no
  /// per-profile `instrument` table to apply it to, so silently log
  /// and skip — never apply.
  nonisolated func applyBatchSaveInstrument(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    guard !ckRecords.isEmpty else { return }
    logger.warning(
      """
      Ignoring \(ckRecords.count, privacy: .public) straggler \
      InstrumentRecord save(s) delivered to per-profile zone \
      \(self.zoneID.zoneName, privacy: .public) — shared registry on \
      the profile-index zone is the canonical source.
      """
    )
  }

  nonisolated func applyBatchSaveAccount(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[Account]")
    let rows = mapRows(
      context: context,
      fieldValues: AccountRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.accounts.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveCategory(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[Category]")
    let rows = mapRows(
      context: context,
      fieldValues: CategoryRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.categories.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveTransferSuggestion(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[TransferSuggestion]")
    let rows = mapRows(
      context: context,
      fieldValues: TransferSuggestionRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.transferSuggestions.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveAccountGroup(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[AccountGroup]")
    let rows = mapRows(
      context: context,
      fieldValues: AccountGroupRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(for: row.instrumentId)
        return row
      })
    try writeRemote(site: context.site) {
      try grdbRepositories.accountGroups.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveInsightDismissal(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[InsightDismissal]")
    let rows = mapRows(
      context: context,
      fieldValues: InsightDismissalRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.insightDismissals.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveWalletSyncCheckpoint(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[WalletSyncCheckpoint]")
    let rows = mapRows(
      context: context,
      fieldValues: WalletSyncCheckpointRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    // Plain upsert (no apply-time max-merge): the never-lower-the-shared-value
    // rule is enforced on the write side (`WalletApplyEngine.updateSyncState`
    // saves `max(existing, head)`), so an inbound record already carries the
    // max its origin device knew. A stale lower echo is rejected by the
    // `needs_push` apply guard and the modification-date gate, exactly like
    // every other synced row.
    try writeRemote(site: context.site) {
      try grdbRepositories.walletSyncCheckpoints.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveEarmark(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[Earmark]")
    let rows = mapRows(
      context: context,
      fieldValues: EarmarkRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(for: row.instrumentId)
        row.savingsTargetInstrumentId =
          self.canonicalInstrumentId(for: row.savingsTargetInstrumentId)
        return row
      })
    try writeRemote(site: context.site) {
      try grdbRepositories.earmarks.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveEarmarkBudgetItem(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[EarmarkBudgetItem]")
    let rows = mapRows(
      context: context,
      fieldValues: EarmarkBudgetItemRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(for: row.instrumentId)
        return row
      })
    try writeRemote(site: context.site) {
      try grdbRepositories.earmarkBudgetItems.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveInvestmentValue(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[InvestmentValue]")
    let rows = mapRows(
      context: context,
      fieldValues: InvestmentValueRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(for: row.instrumentId)
        return row
      })
    try writeRemote(site: context.site) {
      try grdbRepositories.investmentValues.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveTransaction(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[Transaction]")
    let rows = mapRows(
      context: context,
      fieldValues: TransactionRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.transactions.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func applyBatchSaveTransactionLeg(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[TransactionLeg]")
    let rows = mapRows(
      context: context,
      fieldValues: TransactionLegRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields,
      canonicalize: { row in
        var row = row
        row.instrumentId = self.canonicalInstrumentId(for: row.instrumentId)
        return row
      })
    try writeRemote(site: context.site) {
      try grdbRepositories.transactionLegs.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  // MARK: - Mapping & Logging Helpers

  /// Canonicalizes a stored FK instrument id via the injected resolver,
  /// or returns it unchanged when no resolver is wired (preview/tests).
  /// Synchronous and lock-guarded — safe from this `nonisolated` context.
  nonisolated private func canonicalInstrumentId(for id: String) -> String {
    canonicalResolver?.canonicalId(for: id) ?? id
  }

  /// Optional overload for nullable FK columns (e.g. `EarmarkRow`).
  nonisolated private func canonicalInstrumentId(for id: String?) -> String? {
    id.map { canonicalInstrumentId(for: $0) }
  }

  /// Generic `stamp` closure shared by every save helper: copies the
  /// per-row encoded system fields blob onto the row before it lands
  /// in GRDB.
  nonisolated func stampSystemFields<Row: GRDBSystemFieldsStampable>(
    _ row: Row, _ data: Data?
  ) -> Row {
    var copy = row
    copy.encodedSystemFields = data
    return copy
  }

  /// Decodes a batch of `CKRecord` values into typed GRDB rows, stamping
  /// each row's `encodedSystemFields` from the per-batch lookup and
  /// applying an optional post-stamp transform (e.g. instrument-id
  /// canonicalization). Skips (and logs) any record whose `fieldValues`
  /// returns `nil`.
  ///
  /// `idKey` extracts the per-row lookup key for the system-fields
  /// dictionary — `.id.uuidString` for UUID-keyed rows, `.id` for the
  /// string-keyed `InstrumentRow`.
  /// `canonicalize` defaults to the identity transform; callers that
  /// require no instrument-id remapping may omit it.
  nonisolated func mapRows<Row>(
    context: GRDBBatchSaveContext,
    fieldValues: (CKRecord) -> Row?,
    idKey: (Row) -> String,
    stamp: (Row, Data?) -> Row,
    canonicalize: (Row) -> Row = { $0 }
  ) -> [Row] {
    context.ckRecords.compactMap { ckRecord -> Row? in
      guard let row = fieldValues(ckRecord) else {
        Self.logMalformed(context.site, ckRecord)
        return nil
      }
      return canonicalize(stamp(row, context.systemFields[idKey(row)]))
    }
  }

  /// Common error-handling shell for GRDB-side remote batch writes.
  /// Logs at error level on throw and rethrows so `applyRemoteChanges`
  /// returns `.saveFailed(...)` and CKSyncEngine refetches.
  nonisolated func writeRemote(
    site: String, _ work: () throws -> Void
  ) throws {
    do {
      try work()
    } catch {
      Self.batchLogger.error(
        """
        \(site, privacy: .public) profile \
        \(self.profileId, privacy: .public) failed: \
        \(error.localizedDescription, privacy: .public)
        """)
      throw error
    }
  }

  /// Logs a malformed incoming CKRecord at error level so the skip is
  /// visible in diagnostics rather than silently dropped.
  nonisolated static func logMalformed(_ site: String, _ ckRecord: CKRecord) {
    batchLogger.error(
      "\(site): malformed recordID '\(ckRecord.recordID.recordName)' (recordType \(ckRecord.recordType)) — skipping"
    )
  }
}
