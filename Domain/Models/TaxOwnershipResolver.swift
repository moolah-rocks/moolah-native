import Foundation

struct TaxOwnerAllocation: Sendable, Hashable {
  let ownerId: UUID
  let fraction: Decimal
}

struct TaxOwnershipResolver: Sendable {
  private let profileDefaultOwnerId: UUID
  private let accountsById: [UUID: Account]
  private let categoriesById: [UUID: Category]

  init(
    profileDefaultOwnerId: UUID,
    accounts: [Account],
    categories: [Category]
  ) {
    self.profileDefaultOwnerId = profileDefaultOwnerId
    self.accountsById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    self.categoriesById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
  }

  init(
    profileDefaultOwnerId: UUID,
    accounts: Accounts,
    categories: Categories
  ) {
    self.profileDefaultOwnerId = profileDefaultOwnerId
    self.accountsById = Dictionary(uniqueKeysWithValues: accounts.ordered.map { ($0.id, $0) })
    self.categoriesById = Dictionary(
      uniqueKeysWithValues: categories.flattenedByPath().map { ($0.category.id, $0.category) })
  }

  func allocationsForLeg(_ leg: TransactionLeg) -> [TaxOwnerAllocation] {
    if let categoryId = leg.categoryId,
      let category = categoriesById[categoryId],
      !category.taxOwnerIds.isEmpty
    {
      return allocations(fromResolvedOwnerIds: resolvedOwnerIds(category.taxOwnerIds))
    }
    return allocationsForAccount(leg.accountId)
  }

  func allocationsForAccount(_ accountId: UUID?) -> [TaxOwnerAllocation] {
    if let accountId,
      let account = accountsById[accountId],
      !account.taxOwnerIds.isEmpty
    {
      return allocations(fromResolvedOwnerIds: resolvedOwnerIds(account.taxOwnerIds))
    }
    return allocations(fromResolvedOwnerIds: [profileDefaultOwnerId])
  }

  private func resolvedOwnerIds(_ ownerIds: [UUID]) -> [UUID] {
    var seen: Set<UUID> = []
    var resolved: [UUID] = []
    for ownerId in ownerIds where seen.insert(ownerId).inserted {
      resolved.append(ownerId)
    }
    return resolved
  }

  private func allocations(fromResolvedOwnerIds ownerIds: [UUID]) -> [TaxOwnerAllocation] {
    let fraction = Decimal(1) / Decimal(ownerIds.count)
    return ownerIds.map { TaxOwnerAllocation(ownerId: $0, fraction: fraction) }
  }
}
