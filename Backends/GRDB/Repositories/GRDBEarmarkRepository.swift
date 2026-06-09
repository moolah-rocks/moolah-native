// Backends/GRDB/Repositories/GRDBEarmarkRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `EarmarkRepository`. Replaces the
/// SwiftData-backed `CloudKitEarmarkRepository` for the `earmark` and
/// `earmark_budget_item` tables.
///
/// **Default instrument.** `EarmarkRow.instrumentId` is nullable to
/// preserve byte-identity with legacy CloudKit records that didn't carry
/// the column. When the row's `instrumentId` is `nil`, `toDomain(...)`
/// labels the earmark in `defaultInstrument` — typically the active
/// profile's currency. The repository receives that value at init,
/// matching `CloudKitEarmarkRepository.instrument`.
///
/// **Position computation.** `fetchAll()` returns earmarks with their
/// per-instrument `positions`, `savedPositions`, and `spentPositions`
/// populated. The three lists are summed from non-scheduled
/// `transaction_leg` rows grouped by instrument: every earmark-tagged
/// leg contributes to `positions`; income/openingBalance/trade legs
/// contribute to `savedPositions`; expense/transfer legs contribute to
/// `spentPositions` (sign-flipped). Matches
/// `CloudKitEarmarkRepository.computeEarmarkPositions`.
///
/// **Instrument resolution.** Positions resolve their `instrument` via
/// the injected `instrumentResolver`. The instrument map is fetched
/// once, *before* opening the per-profile read snapshot, because the
/// canonical registry lives on a different (profile-index) database — a
/// cross-database transaction is impossible. Instrument identity is
/// immutable lookup data, so a read that is not atomic with the
/// earmark/leg-row snapshot is safe and intended. Mirrors
/// `GRDBTransactionRepository`.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `defaultInstrument` is a value type. `instrumentResolver`
/// is a `Sendable` protocol (`InstrumentMapResolving`) and immutable
/// post-init. `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data race;
/// `@unchecked` only waives Swift's structural check that `final class`
/// types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBEarmarkRepository: EarmarkRepository, @unchecked Sendable {
  // `database`, `defaultInstrument`, `instrumentResolver`, and
  // `errorChannel` are deliberately not `private` so the sibling
  // `+Observation.swift` extension can reach them. Treat them as
  // private-by-convention from elsewhere in the module.
  let database: any DatabaseWriter
  let defaultInstrument: Instrument
  /// Resolves the `[String: Instrument]` lookup table from the
  /// canonical instrument registry. Fetched once per read operation
  /// *before* the per-profile snapshot opens — the registry lives on a
  /// separate (profile-index) database, so a cross-database transaction
  /// is impossible. Instrument identity is immutable lookup data.
  /// Every caller — production, preview, test, and the sync apply path
  /// — injects the shared `GRDBInstrumentRegistryRepository`; nothing
  /// reads the per-profile `instrument` table
  /// `v10_drop_shared_instrument_legacy` removed.
  let instrumentResolver: any InstrumentMapResolving
  /// Receives `(recordType, id)` so budget-item upserts emit the
  /// `EarmarkBudgetItemRow.recordType` rather than being mis-tagged as
  /// `EarmarkRow.recordType`. See `RepositoryHookRecordTypeTests`.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// Single shared error channel for every `observeAll()` /
  /// `observeBudget(earmarkId:)` subscription returned by this repo
  /// instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. Matches `GRDBAccountRepository.errorChannel`.
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    defaultInstrument: Instrument,
    instrumentResolver: any InstrumentMapResolving,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.defaultInstrument = defaultInstrument
    self.instrumentResolver = instrumentResolver
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - EarmarkRepository conformance

  func fetchAll() async throws -> [Earmark] {
    let defaultInstrument = self.defaultInstrument
    // Resolve the instrument lookup table before opening the
    // per-profile snapshot: the canonical registry is a separate
    // database, so the map cannot be joined into this transaction.
    // Instrument identity is immutable lookup data — a read not atomic
    // with the row snapshot is safe and intended. Mirrors
    // `GRDBTransactionRepository.fetchAll(filter:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    return try await database.read { database in
      let positionsByEarmark = try Self.computeEarmarkPositions(
        database: database, instruments: instruments)
      let rows =
        try EarmarkRow
        .order(EarmarkRow.Columns.position.asc)
        .fetchAll(database)
      return rows.map { row in
        let lists = positionsByEarmark[row.id] ?? EarmarkPositionLists.empty
        return row.toDomain(
          defaultInstrument: defaultInstrument,
          positions: lists.positions,
          savedPositions: lists.savedPositions,
          spentPositions: lists.spentPositions)
      }
    }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let row = EarmarkRow(domain: earmark)
    try await database.write { database in
      try row.insert(database)
      try markNeedsPushSync(id: earmark.id, in: database)
    }
    onRecordChanged(EarmarkRow.recordType, earmark.id)
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    try await database.write { database in
      guard
        var existing =
          try EarmarkRow
          .filter(EarmarkRow.Columns.id == earmark.id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }
      existing.name = earmark.name
      existing.position = earmark.position
      existing.isHidden = earmark.isHidden
      existing.instrumentId = earmark.instrument.id
      existing.savingsTarget = earmark.savingsGoal?.storageValue
      existing.savingsTargetInstrumentId = earmark.savingsGoal?.instrument.id
      existing.savingsStartDate = earmark.savingsStartDate
      existing.savingsEndDate = earmark.savingsEndDate
      try existing.update(database)
      try markNeedsPushSync(id: earmark.id, in: database)
    }
    onRecordChanged(EarmarkRow.recordType, earmark.id)
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let defaultInstrument = self.defaultInstrument
    return try await database.read { database in
      // Resolve the earmark's instrument first so budget items inherit
      // the same instrument label — mirrors `CloudKitEarmarkRepository`
      // (rows whose own `instrumentId` is nil fall back to the
      // repository's `defaultInstrument`).
      let earmarkInstrument: Instrument
      if let earmarkRow =
        try EarmarkRow
        .filter(EarmarkRow.Columns.id == earmarkId)
        .fetchOne(database)
      {
        earmarkInstrument =
          earmarkRow.instrumentId.map { Instrument.fiat(code: $0) }
          ?? defaultInstrument
      } else {
        earmarkInstrument = defaultInstrument
      }

      let rows =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.earmarkId == earmarkId)
        .fetchAll(database)
      return rows.map { $0.toDomain(earmarkInstrument: earmarkInstrument) }
    }
  }

  func setBudget(
    earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount
  ) async throws {
    let defaultInstrument = self.defaultInstrument
    let outcome = try await database.write { database -> SetBudgetOutcome in
      try Self.performSetBudget(
        database: database,
        earmarkId: earmarkId,
        categoryId: categoryId,
        amount: amount,
        defaultInstrument: defaultInstrument)
    }

    if let changedId = outcome.changedId {
      onRecordChanged(EarmarkBudgetItemRow.recordType, changedId)
    }
    if let deletedId = outcome.deletedId {
      onRecordDeleted(EarmarkBudgetItemRow.recordType, deletedId)
    }
  }

  /// Single-statement body of `setBudget`'s `database.write { … }`
  /// closure. Validates that the amount's instrument matches the
  /// earmark's, then upserts (or deletes for zero amounts) the
  /// matching `EarmarkBudgetItemRow`. Mirrors
  /// `CloudKitEarmarkRepository.performSetBudget`.
  private static func performSetBudget(
    database: Database,
    earmarkId: UUID,
    categoryId: UUID,
    amount: InstrumentAmount,
    defaultInstrument: Instrument
  ) throws -> SetBudgetOutcome {
    guard
      let earmarkRow =
        try EarmarkRow
        .filter(EarmarkRow.Columns.id == earmarkId)
        .fetchOne(database)
    else {
      throw BackendError.serverError(404)
    }
    let earmarkInstrument =
      earmarkRow.instrumentId.map { Instrument.fiat(code: $0) }
      ?? defaultInstrument
    if !amount.isZero, amount.instrument != earmarkInstrument {
      throw BackendError.unsupportedInstrument(
        "Budget amount uses \(amount.instrument.id); earmark uses \(earmarkInstrument.id). "
          + "Budget items must share the earmark's instrument."
      )
    }

    let existing =
      try EarmarkBudgetItemRow
      .filter(
        EarmarkBudgetItemRow.Columns.earmarkId == earmarkId
          && EarmarkBudgetItemRow.Columns.categoryId == categoryId
      )
      .fetchOne(database)

    // Zero-amount writes remove the existing entry (if any). Mirrors
    // `CloudKitEarmarkRepository.upsertBudgetRecord`.
    if amount.isZero {
      guard let existing else { return SetBudgetOutcome(changedId: nil, deletedId: nil) }
      let deletedId = existing.id
      try existing.delete(database)
      return SetBudgetOutcome(changedId: nil, deletedId: deletedId)
    }

    if var existing {
      existing.amount = amount.storageValue
      existing.instrumentId = amount.instrument.id
      try existing.update(database)
      try markBudgetItemNeedsPush(id: existing.id, in: database)
      return SetBudgetOutcome(changedId: existing.id, deletedId: nil)
    }

    let newItem = EarmarkBudgetItem(
      id: UUID(),
      categoryId: categoryId,
      amount: amount)
    let row = EarmarkBudgetItemRow(domain: newItem, earmarkId: earmarkId)
    try row.insert(database)
    try markBudgetItemNeedsPush(id: row.id, in: database)
    return SetBudgetOutcome(changedId: row.id, deletedId: nil)
  }

  // MARK: - Helpers

  /// Captures the id touched by `setBudget(...)` so the caller can fan
  /// out the right hook (`onRecordChanged` for upsert, `onRecordDeleted`
  /// for zero-amount removal) after the write transaction commits.
  private struct SetBudgetOutcome {
    let changedId: UUID?
    let deletedId: UUID?
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(saved rows: [EarmarkRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [EarmarkRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids {
      // Replaces v3's ON DELETE CASCADE on earmark_budget_item.earmark_id
      // and ON DELETE SET NULL on transaction_leg.earmark_id (both
      // dropped in v5_drop_foreign_keys).
      _ =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.earmarkId == id)
        .deleteAll(database)
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.earmarkId == id)
        .updateAll(
          database,
          [TransactionLegRow.Columns.earmarkId.set(to: nil)])
      _ = try EarmarkRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try EarmarkRow
        .filter(EarmarkRow.Columns.id == id)
        .updateAll(database, [EarmarkRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try EarmarkRow
        .updateAll(
          database,
          [EarmarkRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try EarmarkRow
        .filter(EarmarkRow.Columns.encodedSystemFields == nil)
        .select(EarmarkRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try EarmarkRow
        .select(EarmarkRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> EarmarkRow? {
    try database.read { database in
      try EarmarkRow
        .filter(EarmarkRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [EarmarkRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try EarmarkRow
        .filter(idSet.contains(EarmarkRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try EarmarkRow.deleteAll(database)
    }
  }
}
