import Foundation
import GRDB

/// GRDB-backed `InsightDismissalRepository`. One row per `InsightKind`;
/// `recordDismissal` increments atomically inside a single writer
/// transaction. Observation lives in the `+Observation` sibling, the
/// system-fields batch helper in `+Sync`.
///
/// **`@unchecked Sendable` justification.** All stored properties are `let`.
/// `database` is `Sendable` (GRDB protocol guarantee — its serial executor
/// mediates concurrent access). `onRecordChanged` / `onRecordDeleted` are
/// `@Sendable` closures captured at init. `errorChannel` is an `actor`.
/// Nothing mutates post-init. See `guides/CONCURRENCY_GUIDE.md` §2 Carve-out 3
/// (GRDB repositories).
final class GRDBInsightDismissalRepository: InsightDismissalRepository, @unchecked Sendable {
  let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
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

  func fetchAll() async throws -> [InsightDismissal] {
    try await database.read { database in
      try InsightDismissalRow
        .order(InsightDismissalRow.Columns.kind.asc)
        .fetchAll(database)
        .compactMap { $0.toDomain() }
    }
  }

  @discardableResult
  func recordDismissal(of kind: InsightKind) async throws -> InsightDismissal {
    // Read-modify-write inside ONE write block. GRDB's writer is serial, so
    // no other write interleaves — the increment is atomic without raw SQL.
    let row = try await database.write { database -> InsightDismissalRow in
      let id = InsightDismissalRow.id(for: kind)
      var row =
        try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.id == id)
        .fetchOne(database) ?? InsightDismissalRow(kind: kind, count: 0)
      row.count += 1
      try row.upsert(database)
      return row
    }
    onRecordChanged(InsightDismissalRow.recordType, row.id)
    // `toDomain()` only returns nil for an unknown raw value; `kind` here is a
    // live case, so force is safe. Fall back defensively to a fresh tally.
    return row.toDomain() ?? InsightDismissal(kind: kind, count: row.count)
  }

  // Sync entry points are synchronous and block the GRDB queue. They are
  // called from the CKSyncEngine delegate executor off `@MainActor`. Never
  // call these from the main actor. See GRDBAccountGroupRepository for the
  // shared rationale.

  func applyRemoteChangesSync(saved rows: [InsightDismissalRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  func applyRemoteChangesSync(
    saved rows: [InsightDismissalRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows { try row.upsert(database) }
    for id in ids {
      _ = try InsightDismissalRow.deleteOne(database, id: id)
    }
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.id == id)
        .updateAll(database, [InsightDismissalRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InsightDismissalRow
        .updateAll(
          database,
          [InsightDismissalRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.encodedSystemFields == nil)
        .select(InsightDismissalRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InsightDismissalRow
        .select(InsightDismissalRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func fetchRowSync(id: UUID) throws -> InsightDismissalRow? {
    try database.read { database in
      try InsightDismissalRow
        .filter(InsightDismissalRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  func fetchRowsSync(ids: [UUID]) throws -> [InsightDismissalRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InsightDismissalRow
        .filter(idSet.contains(InsightDismissalRow.Columns.id))
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try InsightDismissalRow.deleteAll(database)
    }
  }
}
