// Backends/GRDB/Repositories/GRDBInvestmentRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `InvestmentRepository`. Replaces the
/// SwiftData-backed `CloudKitInvestmentRepository` for the
/// `investment_value` table.
///
/// **Composite uniqueness** on `(account_id, date)` is enforced at the
/// repository layer (matching the SwiftData status quo), not as a SQL
/// UNIQUE constraint — `setValue(...)` does an explicit
/// `SELECT … LIMIT 1` followed by `UPDATE` or `INSERT` so a same-day
/// re-write replaces in place.
///
/// **Instrument resolution.** `fetchDailyBalances(...)` resolves each
/// leg's `instrument` via the injected `instrumentResolver`. The
/// instrument map is fetched once, *before* opening the per-profile
/// read snapshot, because the canonical registry lives on a different
/// (profile-index) database — a cross-database transaction is
/// impossible. Instrument identity is immutable lookup data, so a read
/// that is not atomic with the leg-row snapshot is safe and intended.
/// Mirrors `GRDBTransactionRepository`.
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
final class GRDBInvestmentRepository: InvestmentRepository, @unchecked Sendable {
  // `database`, `defaultInstrument`, `instrumentResolver`, and
  // `errorChannel` are deliberately not `private` so the sibling
  // `+Observation.swift` extension can reach them. Treat them as
  // private-by-convention from elsewhere in the module.
  let database: any DatabaseWriter
  /// Used as the labelling instrument on `AccountDailyBalance` rows
  /// returned from `fetchDailyBalances(...)`. Mirrors
  /// `CloudKitInvestmentRepository.instrument`.
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
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// Single shared error channel for every `observeValues(...)` /
  /// `observeDailyBalances(...)` subscription returned by this repo
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

  // MARK: - InvestmentRepository conformance

  func fetchValues(
    accountId: UUID, page: Int, pageSize: Int
  ) async throws -> InvestmentValuePage {
    try await database.read { database in
      // Fetch one extra row to detect `hasMore` without a separate
      // count query. Trim before mapping.
      let rows =
        try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.accountId == accountId)
        .order(InvestmentValueRow.Columns.date.desc)
        .limit(pageSize + 1, offset: page * pageSize)
        .fetchAll(database)
      let hasMore = rows.count > pageSize
      let values = rows.prefix(pageSize).map { $0.toDomain() }
      return InvestmentValuePage(values: Array(values), hasMore: hasMore)
    }
  }

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async throws {
    let normalisedDate = Calendar.current.startOfDay(for: date)
    let changedId = try await database.write { database -> UUID in
      if var existing =
        try InvestmentValueRow
        .filter(
          InvestmentValueRow.Columns.accountId == accountId
            && InvestmentValueRow.Columns.date == normalisedDate
        )
        .fetchOne(database)
      {
        existing.value = value.storageValue
        existing.instrumentId = value.instrument.id
        try existing.update(database)
        return existing.id
      }

      let id = UUID()
      let row = InvestmentValueRow(
        id: id,
        recordName: InvestmentValueRow.recordName(for: id),
        accountId: accountId,
        date: normalisedDate,
        value: value.storageValue,
        instrumentId: value.instrument.id,
        encodedSystemFields: nil)
      try row.insert(database)
      return id
    }
    onRecordChanged(InvestmentValueRow.recordType, changedId)
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let normalisedDate = Calendar.current.startOfDay(for: date)
    let deletedId = try await database.write { database -> UUID in
      guard
        let existing =
          try InvestmentValueRow
          .filter(
            InvestmentValueRow.Columns.accountId == accountId
              && InvestmentValueRow.Columns.date == normalisedDate
          )
          .fetchOne(database)
      else {
        throw BackendError.notFound("Investment value not found")
      }
      let id = existing.id
      try existing.delete(database)
      return id
    }
    onRecordDeleted(InvestmentValueRow.recordType, deletedId)
  }

  func removeAllValues(accountId: UUID) async throws -> Int {
    // Collect the ids in the same transaction that deletes them so the
    // CloudKit-deletion enqueue below covers exactly the rows removed.
    // `removeValue` normalises to `startOfDay` and matches one row; this
    // bulk path deletes every row for the account in one statement
    // regardless of the stored time-of-day, so a per-date loop is wrong.
    let deletedIds = try await database.write { database -> [UUID] in
      let request =
        InvestmentValueRow
        .filter(InvestmentValueRow.Columns.accountId == accountId)
      let ids =
        try request
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
      _ = try request.deleteAll(database)
      return ids
    }
    for id in deletedIds {
      onRecordDeleted(InvestmentValueRow.recordType, id)
    }
    return deletedIds.count
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    let defaultInstrument = self.defaultInstrument
    // Resolve the instrument lookup table before opening the
    // per-profile snapshot: the canonical registry is a separate
    // database, so the map cannot be joined into this transaction.
    // Instrument identity is immutable lookup data — a read not atomic
    // with the leg-row snapshot is safe and intended. Mirrors
    // `GRDBTransactionRepository.fetchAll(filter:)`.
    let instruments = try await instrumentResolver.instrumentMap()
    return try await database.read { database in
      try DailyBalanceCompute.compute(
        database: database,
        accountId: accountId,
        instruments: instruments,
        defaultInstrument: defaultInstrument)
    }
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(
    saved rows: [InvestmentValueRow], deleted ids: [UUID]
  ) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [InvestmentValueRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      _ = try InvestmentValueRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.id == id)
        .updateAll(
          database,
          [InvestmentValueRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Batch counterpart to `setEncodedSystemFieldsSync`. See
  /// `GRDBTransactionRepository.setEncodedSystemFieldsBatchSync` for
  /// the rationale (issue #865 follow-up).
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try InvestmentValueRow
          .filter(InvestmentValueRow.Columns.id == id)
          .updateAll(
            database,
            [InvestmentValueRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InvestmentValueRow
        .updateAll(
          database,
          [InvestmentValueRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.encodedSystemFields == nil)
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InvestmentValueRow
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> InvestmentValueRow? {
    try database.read { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [InvestmentValueRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InvestmentValueRow
        .filter(idSet.contains(InvestmentValueRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try InvestmentValueRow.deleteAll(database)
    }
  }
}
