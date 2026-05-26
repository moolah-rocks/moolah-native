import Foundation
import Testing

@testable import Moolah

@Suite("AccountViewContextBuilder")
@MainActor
struct AccountViewContextBuilderTests {

  // MARK: - Helpers

  private func makeAccount(
    id: UUID = UUID(),
    name: String = "Account",
    type: AccountType = .bank,
    groupId: UUID? = nil,
    position: Int = 0
  ) -> Account {
    Account(
      id: id, name: name, type: type,
      instrument: .defaultTestInstrument,
      positions: [],
      position: position,
      groupId: groupId)
  }

  private func makeGroup(
    id: UUID = UUID(),
    name: String = "Trust Fund Crypto",
    bucket: AccountBucket = .investments,
    position: Int = 0
  ) -> AccountGroup {
    AccountGroup(
      id: id, name: name, bucket: bucket,
      instrument: .defaultTestInstrument,
      position: position)
  }

  // MARK: - .account

  @Test("account selection → 1-element accountIds, kind .account")
  func accountSelectionSingleId() throws {
    let account = makeAccount(name: "Checking")
    let accounts = Accounts(from: [account])

    let context = try #require(
      AccountViewContextBuilder.build(
        for: .account(account.id),
        accounts: accounts,
        groups: [],
        syncStatuses: [:]))

    #expect(context.kind == .account)
    #expect(context.accountIds == [account.id])
    #expect(context.displayName == "Checking")
    #expect(context.bucket == .current)
    #expect(context.syncStatus == .allSynced)
  }

  @Test("account selection picks up per-account sync status")
  func accountSelectionSyncStatus() {
    let account = makeAccount(type: .crypto)
    let accounts = Accounts(from: [account])

    let context = AccountViewContextBuilder.build(
      for: .account(account.id),
      accounts: accounts,
      groups: [],
      syncStatuses: [
        account.id: AccountSyncStatus(
          accountId: account.id, isInProgress: true, hasError: false)
      ])

    #expect(context?.syncStatus == .syncing(done: 0, total: 1))
  }

  @Test("account selection with unknown id returns nil")
  func accountSelectionUnknownIdReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .account(UUID()),
      accounts: accounts,
      groups: [],
      syncStatuses: [:])

    #expect(context == nil)
  }

  // MARK: - .group

  @Test("group selection → N-element accountIds ordered by member position")
  func groupSelectionIdsOrderedByPosition() throws {
    let group = makeGroup()
    let memberA = makeAccount(
      id: UUID(), name: "ETH wallet", type: .crypto, groupId: group.id, position: 1)
    let memberB = makeAccount(
      id: UUID(), name: "Coinstash", type: .crypto, groupId: group.id, position: 0)
    let memberC = makeAccount(
      id: UUID(), name: "Polygon wallet", type: .crypto, groupId: group.id, position: 2)
    let accounts = Accounts(from: [memberA, memberB, memberC])

    let context = try #require(
      AccountViewContextBuilder.build(
        for: .group(group.id),
        accounts: accounts,
        groups: [group],
        syncStatuses: [:]))

    #expect(context.kind == .group)
    #expect(context.accountIds == [memberB.id, memberA.id, memberC.id])
    #expect(context.displayName == "Trust Fund Crypto")
    #expect(context.bucket == .investments)
  }

  @Test("group selection only includes members of that group")
  func groupSelectionFiltersMembers() {
    let group = makeGroup()
    let otherGroup = makeGroup(id: UUID(), name: "Other")
    let member = makeAccount(
      id: UUID(), name: "Member", type: .crypto, groupId: group.id, position: 0)
    let otherMember = makeAccount(
      id: UUID(), name: "Other Member", type: .crypto, groupId: otherGroup.id, position: 0)
    let standalone = makeAccount(
      id: UUID(), name: "Standalone", type: .crypto, groupId: nil, position: 5)
    let accounts = Accounts(from: [member, otherMember, standalone])

    let context = AccountViewContextBuilder.build(
      for: .group(group.id),
      accounts: accounts,
      groups: [group, otherGroup],
      syncStatuses: [:])

    #expect(context?.accountIds == [member.id])
  }

  @Test("group selection with zero members → empty accountIds")
  func groupSelectionZeroMembers() throws {
    let group = makeGroup()
    let accounts = Accounts(from: [])

    let context = try #require(
      AccountViewContextBuilder.build(
        for: .group(group.id),
        accounts: accounts,
        groups: [group],
        syncStatuses: [:]))

    #expect(context.accountIds.isEmpty == true)
    #expect(context.syncStatus == .allSynced)
  }

  @Test("group selection with unknown id returns nil")
  func groupSelectionUnknownIdReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .group(UUID()),
      accounts: accounts,
      groups: [],
      syncStatuses: [:])

    #expect(context == nil)
  }

  @Test("group selection aggregates per-member sync statuses")
  func groupSelectionAggregatesSync() {
    let group = makeGroup()
    let memberA = makeAccount(
      id: UUID(), name: "A", type: .crypto, groupId: group.id, position: 0)
    let memberB = makeAccount(
      id: UUID(), name: "B", type: .crypto, groupId: group.id, position: 1)
    let accounts = Accounts(from: [memberA, memberB])

    let context = AccountViewContextBuilder.build(
      for: .group(group.id),
      accounts: accounts,
      groups: [group],
      syncStatuses: [
        memberA.id: AccountSyncStatus(
          accountId: memberA.id, isInProgress: false, hasError: false),
        memberB.id: AccountSyncStatus(
          accountId: memberB.id, isInProgress: false, hasError: true),
      ])

    #expect(context?.syncStatus == .failed(memberIds: [memberB.id]))
  }

  // MARK: - non-detail selections

  @Test("earmark selection returns nil (separate detail view)")
  func earmarkSelectionReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .earmark(UUID()),
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }

  @Test("allTransactions selection returns nil")
  func allTransactionsReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .allTransactions,
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }

  @Test("reports selection returns nil")
  func reportsReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .reports,
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }

  @Test("analysis selection returns nil")
  func analysisReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .analysis,
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }

  @Test("upcomingTransactions selection returns nil")
  func upcomingReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .upcomingTransactions,
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }

  @Test("categories selection returns nil")
  func categoriesReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .categories,
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }

  @Test("recentlyAdded selection returns nil")
  func recentlyAddedReturnsNil() {
    let accounts = Accounts(from: [])
    let context = AccountViewContextBuilder.build(
      for: .recentlyAdded,
      accounts: accounts,
      groups: [],
      syncStatuses: [:])
    #expect(context == nil)
  }
}
