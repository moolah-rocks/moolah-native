// Backends/GRDB/Repositories/GRDBTaxOwnerRepository.swift

import Foundation
import GRDB
import os

/// `@unchecked Sendable` under the GRDB repository carve-out: `database`
/// serializes reads/writes through GRDB, mutation callbacks are `@Sendable`,
/// `defaultTaxOwnerIdState` is guarded by `OSAllocatedUnfairLock` without
/// suspension while held, and `errorChannel` is actor-backed observation
/// plumbing shared with sibling repositories.
final class GRDBTaxOwnerRepository: TaxOwnerRepository, @unchecked Sendable {
  let database: any DatabaseWriter
  private let defaultTaxOwnerIdState: OSAllocatedUnfairLock<UUID?>
  private let implicitDefaultTaxOwnerId: UUID?
  private let defaultTaxOwnerName: String
  let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  let onAccountChanged: @Sendable (String, UUID) -> Void
  let onCategoryChanged: @Sendable (String, UUID) -> Void
  let errorChannel = ObservationErrorChannel()

  var defaultTaxOwnerId: UUID? {
    defaultTaxOwnerIdState.withLock { $0 }
  }

  init(
    database: any DatabaseWriter,
    defaultTaxOwnerId: UUID? = nil,
    implicitDefaultTaxOwnerId: UUID? = nil,
    defaultTaxOwnerName: String = "Default owner",
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onAccountChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onCategoryChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.defaultTaxOwnerIdState = OSAllocatedUnfairLock(initialState: defaultTaxOwnerId)
    self.implicitDefaultTaxOwnerId = implicitDefaultTaxOwnerId ?? defaultTaxOwnerId
    self.defaultTaxOwnerName = defaultTaxOwnerName
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
    self.onAccountChanged = onAccountChanged
    self.onCategoryChanged = onCategoryChanged
  }

  func fetchAll() async throws -> [TaxOwner] {
    try await database.read { database in
      try fetchRowsWithImplicitDefault(in: database)
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
      try DeletionJournal.clearDataTombstone(
        recordName: TaxOwnerRow.recordName(for: owner.id), in: database)
    }
    onRecordChanged(TaxOwnerRow.recordType, owner.id)
    return owner
  }

  @discardableResult
  func update(_ owner: TaxOwner) async throws -> TaxOwner {
    try await database.write { database in
      if var existing =
        try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.id == owner.id)
        .fetchOne(database)
      {
        existing.name = owner.name
        existing.kind = owner.kind.rawValue
        try existing.update(database)
      } else if owner.id == defaultTaxOwnerId {
        try TaxOwnerRow(domain: owner).insert(database)
      } else {
        throw BackendError.serverError(404)
      }
      try markNeedsPushSync(id: owner.id, in: database)
    }
    onRecordChanged(TaxOwnerRow.recordType, owner.id)
    return owner
  }

  func delete(id: UUID) async throws {
    let result = try await database.write { database in
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
        if id == defaultTaxOwnerId {
          try DeletionJournal.recordDataTombstone(
            recordName: TaxOwnerRow.recordName(for: id),
            recordType: TaxOwnerRow.recordType,
            at: Date(),
            in: database)
        }
      }
      return (references: references, deleted: deleted)
    }
    for accountId in result.references.accountIds {
      onAccountChanged(AccountRow.recordType, accountId)
    }
    for categoryId in result.references.categoryIds {
      onCategoryChanged(CategoryRow.recordType, categoryId)
    }
    if result.deleted > 0 {
      onRecordDeleted(TaxOwnerRow.recordType, id)
    }
  }

  func updateDefaultTaxOwnerId(_ id: UUID) {
    defaultTaxOwnerIdState.withLock { $0 = id }
  }

  func bootstrapImplicitDefaultOwner() throws {
    guard let defaultTaxOwnerId, defaultTaxOwnerId == implicitDefaultTaxOwnerId else { return }
    let inserted = try database.write { database -> Bool in
      let existing =
        try TaxOwnerRow
        .filter(TaxOwnerRow.Columns.id == defaultTaxOwnerId)
        .fetchOne(database)
      guard existing == nil else { return false }
      let recordName = TaxOwnerRow.recordName(for: defaultTaxOwnerId)
      let wasDeleted =
        try DeletionJournal.hasDataTombstone(recordName: recordName, in: database)
        || DeletionJournalRow
          .filter(
            DeletionJournalRow.Columns.zoneName == DeletionJournal.profileDataSentinelZone
              && DeletionJournalRow.Columns.recordName == recordName
          )
          .fetchCount(database) > 0
      guard !wasDeleted else { return false }
      try TaxOwnerRow(
        domain: TaxOwner(id: defaultTaxOwnerId, name: defaultTaxOwnerName)
      ).insert(database)
      try markNeedsPushSync(id: defaultTaxOwnerId, in: database)
      try DeletionJournal.clearDataDeletion(recordName: recordName, in: database)
      try DeletionJournal.clearDataTombstone(recordName: recordName, in: database)
      return true
    }
    if inserted {
      onRecordChanged(TaxOwnerRow.recordType, defaultTaxOwnerId)
    }
  }

  func fetchRowsWithImplicitDefault(in database: Database) throws -> [TaxOwner] {
    var owners = try Self.fetchRows(in: database)
    if let implicitDefaultOwner = try implicitDefaultOwnerIfNeeded(
      existingOwnerIds: Set(owners.map(\.id)),
      in: database)
    {
      owners.append(implicitDefaultOwner)
      owners.sort { lhs, rhs in
        if lhs.name != rhs.name {
          return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    }
    return owners
  }

  private func implicitDefaultOwnerIfNeeded(
    existingOwnerIds: Set<UUID>,
    in database: Database
  ) throws -> TaxOwner? {
    guard let defaultTaxOwnerId, defaultTaxOwnerId == implicitDefaultTaxOwnerId else { return nil }
    guard !existingOwnerIds.contains(defaultTaxOwnerId) else { return nil }
    let recordName = TaxOwnerRow.recordName(for: defaultTaxOwnerId)
    let wasDeleted =
      try DeletionJournal.hasDataTombstone(recordName: recordName, in: database)
      || DeletionJournalRow
        .filter(
          DeletionJournalRow.Columns.zoneName == DeletionJournal.profileDataSentinelZone
            && DeletionJournalRow.Columns.recordName == recordName
        )
        .fetchCount(database) > 0
    guard !wasDeleted else { return nil }
    return TaxOwner(id: defaultTaxOwnerId, name: defaultTaxOwnerName)
  }

  static func fetchRows(in database: Database) throws -> [TaxOwner] {
    try TaxOwnerRow
      .order(TaxOwnerRow.Columns.name.asc)
      .fetchAll(database)
      .map { $0.toDomain() }
  }
}
