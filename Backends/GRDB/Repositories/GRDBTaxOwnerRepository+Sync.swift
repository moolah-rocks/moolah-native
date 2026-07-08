// Backends/GRDB/Repositories/GRDBTaxOwnerRepository+Sync.swift

import Foundation
import GRDB

extension GRDBTaxOwnerRepository {
  func applyRemoteChangesSync(saved rows: [TaxOwnerRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  func applyRemoteChangesSync(
    saved rows: [TaxOwnerRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
      try DeletionJournal.clearDataDeletion(recordName: row.recordName, in: database)
    }
    for id in ids {
      _ = try GRDBTaxOwnershipPersistence.removeOwnerReferences(
        ownerId: id,
        markNeedsPush: false,
        in: database)
      _ = try TaxOwnerRow.deleteOne(database, id: id)
    }
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.id == id)
        .updateAll(database, [TaxOwnerRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try TaxOwnerRow
        .updateAll(database, [TaxOwnerRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.encodedSystemFields == nil)
        .select(TaxOwnerRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try TaxOwnerRow
        .select(TaxOwnerRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func fetchRowSync(id: UUID) throws -> TaxOwnerRow? {
    try database.read { database in
      try fetchRowSync(id: id, in: database)
    }
  }

  func fetchRowSync(id: UUID, in database: Database) throws -> TaxOwnerRow? {
    try TaxOwnerRow
      .filter(TaxOwnerRow.Columns.id == id)
      .fetchOne(database)
  }

  func fetchRowsSync(ids: [UUID]) throws -> [TaxOwnerRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try TaxOwnerRow
        .filter(idSet.contains(TaxOwnerRow.Columns.id))
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try TaxOwnerRow.deleteAll(database)
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
        try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.id == id)
        .updateAll(database, [TaxOwnerRow.Columns.encodedSystemFields.set(to: data)])
    }
    return updatedCount
  }

  func markNeedsPushSync(id: UUID, in database: Database) throws {
    _ =
      try TaxOwnerRow
      .filter(TaxOwnerRow.Columns.id == id)
      .updateAll(database, [TaxOwnerRow.Columns.needsPush.set(to: true)])
  }

  func dirtyIdsSync(from ids: [UUID], in database: Database) throws -> Set<UUID> {
    guard !ids.isEmpty else { return [] }
    let idSet = Set(ids)
    let rows =
      try TaxOwnerRow
      .filter(idSet.contains(TaxOwnerRow.Columns.id))
      .filter(TaxOwnerRow.Columns.needsPush == true)
      .select(TaxOwnerRow.Columns.id, as: UUID.self)
      .fetchAll(database)
    return Set(rows)
  }

  func dirtyIdsSync(from ids: [UUID]) throws -> Set<UUID> {
    try database.read { database in try dirtyIdsSync(from: ids, in: database) }
  }

  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try database.write { database in
      try clearNeedsPushBatchSync(ids, in: database)
    }
  }

  @discardableResult
  func clearNeedsPushBatchSync(_ ids: [UUID], in database: Database) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return
      try TaxOwnerRow
      .filter(Set(ids).contains(TaxOwnerRow.Columns.id))
      .updateAll(database, [TaxOwnerRow.Columns.needsPush.set(to: false)])
  }
}
