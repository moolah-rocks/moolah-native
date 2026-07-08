import Foundation
import Testing

@testable import Moolah

@Suite("Tax ownership resolver")
struct TaxOwnershipResolverTests {
  private let defaultOwner = UUID()
  private let husband = UUID()
  private let wife = UUID()
  private let trust = UUID()
  private let accountId = UUID()
  private let categoryId = UUID()

  @Test
  func fallsBackToProfileDefaultWhenNoAccountOrCategoryOwnersExist() {
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: [],
      categories: [])
    let leg = TransactionLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: 100,
      type: .income)

    #expect(
      resolver.allocationsForLeg(leg) == [
        TaxOwnerAllocation(ownerId: defaultOwner, fraction: 1)
      ])
  }

  @Test
  func accountOwnersOverrideProfileDefault() {
    let account = Account(
      id: accountId,
      name: "Joint",
      type: .bank,
      instrument: .AUD,
      taxOwnerIds: [husband, wife])
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: [account],
      categories: [])
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: .AUD,
      quantity: 100,
      type: .income)

    #expect(
      resolver.allocationsForLeg(leg) == [
        TaxOwnerAllocation(ownerId: husband, fraction: Decimal(1) / Decimal(2)),
        TaxOwnerAllocation(ownerId: wife, fraction: Decimal(1) / Decimal(2)),
      ])
  }

  @Test
  func categoryOwnersOverrideAccountOwners() {
    let account = Account(
      id: accountId,
      name: "Joint",
      type: .bank,
      instrument: .AUD,
      taxOwnerIds: [husband, wife])
    let category = Category(
      id: categoryId,
      name: "Trust expense",
      taxOwnerIds: [trust])
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: [account],
      categories: [category])
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: .AUD,
      quantity: -100,
      type: .expense,
      categoryId: categoryId)

    #expect(
      resolver.allocationsForLeg(leg) == [
        TaxOwnerAllocation(ownerId: trust, fraction: 1)
      ])
  }

  @Test
  func emptyOwnerArraysFallBack() {
    let account = Account(
      id: accountId,
      name: "Empty account owners",
      type: .bank,
      instrument: .AUD,
      taxOwnerIds: [])
    let category = Category(
      id: categoryId,
      name: "Empty category owners",
      taxOwnerIds: [])
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: [account],
      categories: [category])
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: .AUD,
      quantity: 100,
      type: .income,
      categoryId: categoryId)

    #expect(
      resolver.allocationsForLeg(leg) == [
        TaxOwnerAllocation(ownerId: defaultOwner, fraction: 1)
      ])
  }

  @Test
  func arbitraryOwnerCountSplitsEvenly() {
    let account = Account(
      id: accountId,
      name: "Three owners",
      type: .bank,
      instrument: .AUD,
      taxOwnerIds: [husband, wife, trust])
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: [account],
      categories: [])

    #expect(
      resolver.allocationsForAccount(accountId) == [
        TaxOwnerAllocation(ownerId: husband, fraction: Decimal(1) / Decimal(3)),
        TaxOwnerAllocation(ownerId: wife, fraction: Decimal(1) / Decimal(3)),
        TaxOwnerAllocation(ownerId: trust, fraction: Decimal(1) / Decimal(3)),
      ])
  }

  @Test
  func duplicateOwnerIdsAreIgnoredPreservingFirstOccurrenceOrder() {
    let account = Account(
      id: accountId,
      name: "Duplicates",
      type: .bank,
      instrument: .AUD,
      taxOwnerIds: [husband, wife, husband])
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: [account],
      categories: [])

    #expect(
      resolver.allocationsForAccount(accountId) == [
        TaxOwnerAllocation(ownerId: husband, fraction: Decimal(1) / Decimal(2)),
        TaxOwnerAllocation(ownerId: wife, fraction: Decimal(1) / Decimal(2)),
      ])
  }
}
