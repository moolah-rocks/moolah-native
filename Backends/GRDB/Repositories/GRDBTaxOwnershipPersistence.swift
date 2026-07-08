// Backends/GRDB/Repositories/GRDBTaxOwnershipPersistence.swift

import Foundation
import GRDB

enum GRDBTaxOwnershipPersistence {
  struct RemovedOwnerReferences: Sendable {
    let accountIds: [UUID]
    let categoryIds: [UUID]
  }

  static func accountOwnerIdsByAccount(in database: Database) throws -> [UUID: [UUID]] {
    let rows =
      try AccountTaxOwnerRow
      .order(AccountTaxOwnerRow.Columns.accountId.asc, AccountTaxOwnerRow.Columns.position.asc)
      .fetchAll(database)
    return Dictionary(grouping: rows, by: \.accountId).mapValues { $0.map(\.ownerId) }
  }

  static func accountOwnerIdsByAccount(
    accountIds: Set<UUID>,
    in database: Database
  ) throws -> [UUID: [UUID]] {
    guard !accountIds.isEmpty else { return [:] }
    let rows =
      try AccountTaxOwnerRow
      .filter(accountIds.contains(AccountTaxOwnerRow.Columns.accountId))
      .order(AccountTaxOwnerRow.Columns.accountId.asc, AccountTaxOwnerRow.Columns.position.asc)
      .fetchAll(database)
    return Dictionary(grouping: rows, by: \.accountId).mapValues { $0.map(\.ownerId) }
  }

  static func categoryOwnerIdsByCategory(in database: Database) throws -> [UUID: [UUID]] {
    let rows =
      try CategoryTaxOwnerRow
      .order(CategoryTaxOwnerRow.Columns.categoryId.asc, CategoryTaxOwnerRow.Columns.position.asc)
      .fetchAll(database)
    return Dictionary(grouping: rows, by: \.categoryId).mapValues { $0.map(\.ownerId) }
  }

  static func categoryOwnerIdsByCategory(
    categoryIds: Set<UUID>,
    in database: Database
  ) throws -> [UUID: [UUID]] {
    guard !categoryIds.isEmpty else { return [:] }
    let rows =
      try CategoryTaxOwnerRow
      .filter(categoryIds.contains(CategoryTaxOwnerRow.Columns.categoryId))
      .order(CategoryTaxOwnerRow.Columns.categoryId.asc, CategoryTaxOwnerRow.Columns.position.asc)
      .fetchAll(database)
    return Dictionary(grouping: rows, by: \.categoryId).mapValues { $0.map(\.ownerId) }
  }

  static func replaceAccountOwners(
    accountId: UUID, ownerIds: [UUID], in database: Database
  ) throws {
    _ =
      try AccountTaxOwnerRow
      .filter(AccountTaxOwnerRow.Columns.accountId == accountId)
      .deleteAll(database)
    for (position, ownerId) in uniquedPreservingOrder(ownerIds).enumerated() {
      try AccountTaxOwnerRow(
        accountId: accountId,
        ownerId: ownerId,
        position: position
      ).insert(database)
    }
  }

  static func replaceCategoryOwners(
    categoryId: UUID, ownerIds: [UUID], in database: Database
  ) throws {
    _ =
      try CategoryTaxOwnerRow
      .filter(CategoryTaxOwnerRow.Columns.categoryId == categoryId)
      .deleteAll(database)
    for (position, ownerId) in uniquedPreservingOrder(ownerIds).enumerated() {
      try CategoryTaxOwnerRow(
        categoryId: categoryId,
        ownerId: ownerId,
        position: position
      ).insert(database)
    }
  }

  static func deleteAccountOwners(accountId: UUID, in database: Database) throws {
    _ =
      try AccountTaxOwnerRow
      .filter(AccountTaxOwnerRow.Columns.accountId == accountId)
      .deleteAll(database)
  }

  static func deleteCategoryOwners(categoryId: UUID, in database: Database) throws {
    _ =
      try CategoryTaxOwnerRow
      .filter(CategoryTaxOwnerRow.Columns.categoryId == categoryId)
      .deleteAll(database)
  }

  static func removeOwnerReferences(
    ownerId: UUID,
    markNeedsPush: Bool,
    in database: Database
  ) throws -> RemovedOwnerReferences {
    let affectedAccounts = try removeOwnerFromAccounts(
      ownerId: ownerId,
      markNeedsPush: markNeedsPush,
      in: database)
    let affectedCategories = try removeOwnerFromCategories(
      ownerId: ownerId,
      markNeedsPush: markNeedsPush,
      in: database)
    return RemovedOwnerReferences(
      accountIds: affectedAccounts,
      categoryIds: affectedCategories)
  }

  private static func removeOwnerFromAccounts(
    ownerId: UUID,
    markNeedsPush: Bool,
    in database: Database
  ) throws -> [UUID] {
    let accountRows =
      try AccountTaxOwnerRow
      .filter(AccountTaxOwnerRow.Columns.ownerId == ownerId)
      .order(AccountTaxOwnerRow.Columns.accountId.asc)
      .select(AccountTaxOwnerRow.Columns.accountId, as: UUID.self)
      .fetchAll(database)
    let accountIds = uniquedPreservingOrder(accountRows)
    let accountIdSet = Set(accountIds)
    let accountOwnerIds = try accountOwnerIdsByAccount(accountIds: accountIdSet, in: database)
    let rows =
      try AccountRow
      .filter(accountIdSet.contains(AccountRow.Columns.id))
      .fetchAll(database)
    var affected: [UUID] = []
    for row in rows {
      let updatedOwnerIds = (accountOwnerIds[row.id] ?? []).filter { $0 != ownerId }
      var updates: [ColumnAssignment] = [
        AccountRow.Columns.taxOwnerIdsEncoded.set(to: TaxOwnerIDListCoding.encode(updatedOwnerIds))
      ]
      if markNeedsPush {
        updates.append(AccountRow.Columns.needsPush.set(to: true))
      }
      try AccountRow
        .filter(AccountRow.Columns.id == row.id)
        .updateAll(database, updates)
      try replaceAccountOwners(
        accountId: row.id,
        ownerIds: updatedOwnerIds,
        in: database)
      affected.append(row.id)
    }

    return affected
  }

  private static func removeOwnerFromCategories(
    ownerId: UUID,
    markNeedsPush: Bool,
    in database: Database
  ) throws -> [UUID] {
    let categoryRows =
      try CategoryTaxOwnerRow
      .filter(CategoryTaxOwnerRow.Columns.ownerId == ownerId)
      .order(CategoryTaxOwnerRow.Columns.categoryId.asc)
      .select(CategoryTaxOwnerRow.Columns.categoryId, as: UUID.self)
      .fetchAll(database)
    let categoryIds = uniquedPreservingOrder(categoryRows)
    let categoryIdSet = Set(categoryIds)
    let categoryOwnerIds = try categoryOwnerIdsByCategory(categoryIds: categoryIdSet, in: database)
    let rows =
      try CategoryRow
      .filter(categoryIdSet.contains(CategoryRow.Columns.id))
      .fetchAll(database)
    var affected: [UUID] = []
    for row in rows {
      let updatedOwnerIds = (categoryOwnerIds[row.id] ?? []).filter { $0 != ownerId }
      var updates: [ColumnAssignment] = [
        CategoryRow.Columns.taxOwnerIdsEncoded.set(to: TaxOwnerIDListCoding.encode(updatedOwnerIds))
      ]
      if markNeedsPush {
        updates.append(CategoryRow.Columns.needsPush.set(to: true))
      }
      try CategoryRow
        .filter(CategoryRow.Columns.id == row.id)
        .updateAll(database, updates)
      try replaceCategoryOwners(
        categoryId: row.id,
        ownerIds: updatedOwnerIds,
        in: database)
      affected.append(row.id)
    }

    return affected
  }

  private static func uniquedPreservingOrder(_ ids: [UUID]) -> [UUID] {
    var seen: Set<UUID> = []
    var result: [UUID] = []
    for id in ids where seen.insert(id).inserted {
      result.append(id)
    }
    return result
  }
}
