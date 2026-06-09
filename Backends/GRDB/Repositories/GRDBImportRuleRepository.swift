// Backends/GRDB/Repositories/GRDBImportRuleRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `ImportRuleRepository`. Replaces the
/// SwiftData-backed `CloudKitImportRuleRepository` for the `import_rule`
/// table introduced by `v2_csv_import_and_rules`.
///
/// Concurrency: see header on `GRDBCSVImportProfileRepository`.
/// `final class @unchecked Sendable` to keep CKSyncEngine sync entry
/// points synchronous; protocol conformance still uses `async throws`.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBImportRuleRepository: ImportRuleRepository, @unchecked Sendable {
  // `database` and `errorChannel` are deliberately not `private` so the
  // sibling `+Observation.swift` extension can reach them. Treat them
  // as private-by-convention from elsewhere in the module.
  let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// Single shared error channel for every `observeAll()` subscription
  /// returned by this repo instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. Matches `GRDBCategoryRepository.errorChannel`.
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - ImportRuleRepository conformance

  func fetchAll() async throws -> [ImportRule] {
    try await database.read { database in
      try ImportRuleRow
        .order(ImportRuleRow.Columns.position.asc)
        .fetchAll(database)
        .map { try $0.toDomain() }
    }
  }

  func create(_ rule: ImportRule) async throws -> ImportRule {
    let row = ImportRuleRow(domain: rule)
    try await database.write { database in
      try row.insert(database)
      try markNeedsPushSync(id: rule.id, in: database)
    }
    onRecordChanged(ImportRuleRow.recordType, rule.id)
    return try row.toDomain()
  }

  func update(_ rule: ImportRule) async throws -> ImportRule {
    let updated = try await database.write { database -> ImportRuleRow in
      guard
        var existing =
          try ImportRuleRow
          .filter(ImportRuleRow.Columns.id == rule.id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }
      let fresh = ImportRuleRow(domain: rule)
      existing.name = fresh.name
      existing.enabled = fresh.enabled
      existing.position = fresh.position
      existing.matchMode = fresh.matchMode
      existing.conditionsJSON = fresh.conditionsJSON
      existing.actionsJSON = fresh.actionsJSON
      existing.accountScope = fresh.accountScope
      try existing.update(database)
      try markNeedsPushSync(id: rule.id, in: database)
      return existing
    }
    onRecordChanged(ImportRuleRow.recordType, rule.id)
    return try updated.toDomain()
  }

  func delete(id: UUID) async throws {
    let didDelete = try await database.write { database in
      try ImportRuleRow.deleteOne(database, id: id)
    }
    guard didDelete else {
      throw BackendError.serverError(404)
    }
    onRecordDeleted(ImportRuleRow.recordType, id)
  }

  /// Atomically renumber `position` across every existing rule so that
  /// `orderedIds` take positions 0…n-1. Throws
  /// `BackendError.serverError(409)` if the passed ids do not exactly
  /// match the set of stored rule ids. Only ids whose position actually
  /// changed are queued for upload.
  func reorder(_ orderedIds: [UUID]) async throws {
    let changedIds = try await database.write { database -> [UUID] in
      let allRows = try ImportRuleRow.fetchAll(database)
      let storedIds = Set(allRows.map(\.id))
      let requestedIds = Set(orderedIds)
      guard storedIds == requestedIds, allRows.count == orderedIds.count else {
        throw BackendError.serverError(409)
      }
      let indexById = Dictionary(
        uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
      var changed: [UUID] = []
      for var row in allRows {
        let newPosition = indexById[row.id] ?? row.position
        if row.position != newPosition {
          row.position = newPosition
          try row.update(database)
          try markNeedsPushSync(id: row.id, in: database)
          changed.append(row.id)
        }
      }
      return changed
    }
    for id in changedIds { onRecordChanged(ImportRuleRow.recordType, id) }
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Mirrors `GRDBCSVImportProfileRepository`'s sync section. See that
  // file for the full doc-block on threading semantics: each `…Sync`
  // entry point is called from `ProfileDataSyncHandler` on the
  // CKSyncEngine delegate executor and uses the synchronous
  // `DatabaseWriter.write { … }` overload. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(saved rows: [ImportRuleRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [ImportRuleRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      // `upsert` matches on the PK conflict (`id`). Because
      // `recordName(for: id)` is total over `id`, the implied UNIQUE
      // conflict on `record_name` is satisfied by the same row, so a
      // single conflict target suffices.
      try row.upsert(database)
    }
    for id in ids {
      _ = try ImportRuleRow.deleteOne(database, id: id)
    }
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.id == id)
        .updateAll(database, [ImportRuleRow.Columns.encodedSystemFields.set(to: data)])
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
          try ImportRuleRow
          .filter(ImportRuleRow.Columns.id == id)
          .updateAll(
            database,
            [ImportRuleRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// In-transaction counterpart to `setEncodedSystemFieldsBatchSync(_:)`.
  /// Writes against the caller's active `database` (no nested write) so a
  /// dirty echo's system-fields-only update shares the apply transaction
  /// that read `needs_push` (issue #1081).
  @discardableResult
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)], in database: Database
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    var updatedCount = 0
    for (id, data) in updates {
      updatedCount +=
        try ImportRuleRow
        .filter(ImportRuleRow.Columns.id == id)
        .updateAll(database, [ImportRuleRow.Columns.encodedSystemFields.set(to: data)])
    }
    return updatedCount
  }

  /// Sets `needs_push = 1` for `id` inside the caller's write transaction.
  /// See `GRDBAccountRepository.markNeedsPushSync(id:in:)` (issue #1081).
  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try ImportRuleRow
      .filter(ImportRuleRow.Columns.id == id)
      .updateAll(database, [ImportRuleRow.Columns.needsPush.set(to: true)])
  }

  /// Subset of `ids` whose row currently has `needs_push = 1`. See
  /// `GRDBAccountRepository.dirtyIdsSync(from:in:)`.
  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try ImportRuleRow
      .filter(idSet.contains(ImportRuleRow.Columns.id))
      .filter(ImportRuleRow.Columns.needsPush == true)
      .select(ImportRuleRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    return Set(rows)
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { database in try dirtyIdsSync(from: ids, in: database) }
  }

  /// Clears `needs_push` for the given ids in one transaction. Returns the
  /// number of rows updated.
  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { database in
      try ImportRuleRow
        .filter(Set(ids).contains(ImportRuleRow.Columns.id))
        .updateAll(database, [ImportRuleRow.Columns.needsPush.set(to: false)])
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try ImportRuleRow
        .updateAll(
          database,
          [ImportRuleRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.encodedSystemFields == nil)
        .select(ImportRuleRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ImportRuleRow
        .select(ImportRuleRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func fetchRowSync(id: UUID) throws -> ImportRuleRow? {
    try database.read { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  func fetchRowsSync(ids: [UUID]) throws -> [ImportRuleRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try ImportRuleRow
        .filter(idSet.contains(ImportRuleRow.Columns.id))
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try ImportRuleRow.deleteAll(database)
    }
  }
}
