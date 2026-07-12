import Foundation
import GRDB

/// Legacy persistence/sync compatibility for the retired
/// `InvestmentValueRecord` type.
///
/// No feature-facing API exposes this repository. It remains only so the
/// current sync engine can accept, acknowledge, upload, and delete legacy
/// rows until the final retirement migration removes the table and dispatch.
///
/// **`@unchecked Sendable` justification.** All state is immutable after
/// initialization. `database` conforms to GRDB's `DatabaseWriter`, whose
/// serial executor mediates access and whose protocol is `Sendable`.
/// `@unchecked` therefore only waives structural checking for this final
/// reference type. See `guides/CONCURRENCY_GUIDE.md` §2, Carve-out 3.
final class GRDBInvestmentRepository: @unchecked Sendable {
  let database: any DatabaseWriter

  init(database: any DatabaseWriter) {
    self.database = database
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.id == id)
        .updateAll(
          database,
          [InvestmentValueRow.Columns.encodedSystemFields.set(to: data)]) > 0
    }
  }

  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      try setEncodedSystemFieldsBatchSync(updates, in: database)
    }
  }

  @discardableResult
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)], in database: Database
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
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

  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let rows =
      try InvestmentValueRow
      .filter(Set(ids).contains(InvestmentValueRow.Columns.id))
      .filter(InvestmentValueRow.Columns.needsPush == true)
      .select(InvestmentValueRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    return Set(rows)
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { database in
      try dirtyIdsSync(from: ids, in: database)
    }
  }

  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { database in
      try clearNeedsPushBatchSync(ids, in: database)
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ = try InvestmentValueRow.updateAll(
        database,
        [InvestmentValueRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InvestmentValueRow
        .filter(InvestmentValueRow.Columns.encodedSystemFields == nil)
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try InvestmentValueRow
        .select(InvestmentValueRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func fetchRowSync(id: UUID) throws -> InvestmentValueRow? {
    try database.read { database in
      try fetchRowSync(id: id, in: database)
    }
  }

  func fetchRowsSync(ids: [UUID]) throws -> [InvestmentValueRow] {
    try database.read { database in
      try InvestmentValueRow
        .filter(Set(ids).contains(InvestmentValueRow.Columns.id))
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try InvestmentValueRow.deleteAll(database)
    }
  }
}
