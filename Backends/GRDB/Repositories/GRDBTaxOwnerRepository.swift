// Backends/GRDB/Repositories/GRDBTaxOwnerRepository.swift

import Foundation
import GRDB

/// `@unchecked Sendable` under the GRDB repository carve-out: `database`
/// serializes reads/writes through GRDB, mutation callbacks are `@Sendable`,
/// and `errorChannel` is actor-backed observation plumbing shared with
/// sibling repositories.
final class GRDBTaxOwnerRepository: TaxOwnerRepository, @unchecked Sendable {
  let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  private let onAccountChanged: @Sendable (String, UUID) -> Void
  private let onCategoryChanged: @Sendable (String, UUID) -> Void
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onAccountChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onCategoryChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
    self.onAccountChanged = onAccountChanged
    self.onCategoryChanged = onCategoryChanged
  }

  func fetchAll() async throws -> [TaxOwner] {
    try await database.read { database in
      try TaxOwnerRow
        .order(TaxOwnerRow.Columns.name.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  @discardableResult
  func create(_ owner: TaxOwner) async throws -> TaxOwner {
    let row = TaxOwnerRow(domain: owner)
    try await database.write { database in
      try row.insert(database)
      try markNeedsPushSync(id: owner.id, in: database)
      try DeletionJournal.clearDataDeletion(
        recordName: TaxOwnerRow.recordName(for: owner.id), in: database)
    }
    onRecordChanged(TaxOwnerRow.recordType, owner.id)
    return owner
  }

  @discardableResult
  func update(_ owner: TaxOwner) async throws -> TaxOwner {
    try await database.write { database in
      guard
        var existing =
          try TaxOwnerRow
          .filter(TaxOwnerRow.Columns.id == owner.id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }
      existing.name = owner.name
      existing.kind = owner.kind.rawValue
      try existing.update(database)
      try markNeedsPushSync(id: owner.id, in: database)
    }
    onRecordChanged(TaxOwnerRow.recordType, owner.id)
    return owner
  }

  func delete(id: UUID) async throws {
    let references = try await database.write { database in
      let references = try GRDBTaxOwnershipPersistence.removeOwnerReferences(
        ownerId: id,
        markNeedsPush: true,
        in: database)
      let deleted =
        try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.id == id)
        .deleteAll(database)
      if deleted > 0 {
        try DeletionJournal.recordDataDeletion(
          recordName: TaxOwnerRow.recordName(for: id),
          recordType: TaxOwnerRow.recordType,
          at: Date(),
          in: database)
      }
      return references
    }
    for accountId in references.accountIds {
      onAccountChanged(AccountRow.recordType, accountId)
    }
    for categoryId in references.categoryIds {
      onCategoryChanged(CategoryRow.recordType, categoryId)
    }
    onRecordDeleted(TaxOwnerRow.recordType, id)
  }

  func ensureDefaultOwner(id: UUID, name: String) throws {
    let inserted = try database.write { database -> Bool in
      let existing =
        try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.id == id)
        .fetchOne(database)
      guard existing == nil else { return false }
      try TaxOwnerRow(domain: TaxOwner(id: id, name: name)).insert(database)
      try markNeedsPushSync(id: id, in: database)
      try DeletionJournal.clearDataDeletion(
        recordName: TaxOwnerRow.recordName(for: id), in: database)
      return true
    }
    if inserted {
      onRecordChanged(TaxOwnerRow.recordType, id)
    }
  }
}
