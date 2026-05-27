import Foundation
import Testing

@testable import Moolah

@Suite("SidebarOutlineItem tree")
struct SidebarOutlineItemTests {
  @Test("Current bucket: standalone, group, standalone in position order")
  func currentBucketEnumerationContainsStandaloneThenGroups() throws {
    let bankA = Account(
      id: UUID(), name: "A", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false)
    let bankB = Account(
      id: UUID(), name: "B", type: .bank, instrument: .AUD,
      positions: [], position: 2, isHidden: false)
    let group = AccountGroup(
      name: "G", bucket: .current,
      instrument: .AUD, position: 1)
    let member = Account(
      id: UUID(), name: "M", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      groupId: group.id)

    let items = SidebarOutlineItem.tree(
      accounts: Accounts(from: [bankA, bankB, member]),
      groups: [group],
      bucket: .current
    )

    // Three root items: bankA (pos 0), group G (pos 1), bankB (pos 2).
    #expect(items.count == 3)
    #expect(items[0].kind == .account(bankA.id))
    #expect(items[1].kind == .group(group.id))
    #expect(items[2].kind == .account(bankB.id))
    // Group members appear as children of the group node.
    let groupChildren = try #require(items[1].children)
    #expect(groupChildren.count == 1)
    #expect(groupChildren[0].kind == .account(member.id))
  }

  @Test("Investments bucket is empty when no investment accounts exist")
  func investmentsBucketIsEmptyWhenNoInvestmentAccounts() {
    // The section header used to live in the tree; now it's supplied
    // by the surrounding SwiftUI `Section`, so a bucket with no
    // entries produces an empty array (the section still renders).
    let bank = Account(
      id: UUID(), name: "A", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false)
    let items = SidebarOutlineItem.tree(
      accounts: Accounts(from: [bank]), groups: [],
      bucket: .investments
    )
    #expect(items.isEmpty)
  }

  @Test("Dangling groupId renders the member as standalone in its bucket")
  func danglingGroupIdRendersMemberAsStandaloneInTargetBucket() throws {
    // Sync can deliver an Account ahead of its AccountGroup. The
    // ordering helper folds those into the standalone list — this
    // test asserts SidebarOutlineItem inherits that contract.
    let ghostGroupId = UUID()
    let stranded = Account(
      id: UUID(), name: "S", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      groupId: ghostGroupId)
    let items = SidebarOutlineItem.tree(
      accounts: Accounts(from: [stranded]), groups: [],
      bucket: .current
    )
    #expect(items.count == 1)
    #expect(items[0].kind == .account(stranded.id))
  }
}
