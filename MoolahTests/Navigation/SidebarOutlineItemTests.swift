import Foundation
import Testing

@testable import Moolah

@Suite("SidebarOutlineItem tree")
struct SidebarOutlineItemTests {
  @Test("Current bucket enumeration: standalone, group, standalone in position order")
  func currentBucketHeaderEnumerationContainsStandaloneThenGroups() throws {
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
      groups: [group]
    )

    // Two section headers at root: Current Accounts, Investments.
    #expect(items.count == 2)
    let currentHeader = try #require(items.first)
    #expect(currentHeader.kind == .currentAccountsHeader)
    // Children: bankA (pos 0), group G (pos 1), bankB (pos 2).
    let children = try #require(currentHeader.children)
    #expect(children.count == 3)
    #expect(children[0].kind == .account(bankA.id))
    #expect(children[1].kind == .group(group.id))
    #expect(children[2].kind == .account(bankB.id))
    // Group members appear under the group node.
    let groupChildren = try #require(children[1].children)
    #expect(groupChildren.count == 1)
    #expect(groupChildren[0].kind == .account(member.id))
  }

  @Test("Investments header renders even when empty")
  func investmentsHeaderRendersEvenWhenEmpty() {
    // Empty investments section still produces the section header
    // so the user sees "Investments" with a zero-member section.
    let bank = Account(
      id: UUID(), name: "A", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false)
    let items = SidebarOutlineItem.tree(
      accounts: Accounts(from: [bank]), groups: []
    )
    #expect(items.count == 2)
    #expect(items[1].kind == .investmentsHeader)
    #expect(items[1].children?.isEmpty == true)
  }

  @Test("Dangling groupId renders the member as standalone in its bucket")
  func danglingGroupIdRendersMemberAsStandalone() throws {
    // Sync can deliver an Account ahead of its AccountGroup. The
    // ordering helper folds those into the standalone list — this
    // test asserts SidebarOutlineItem inherits that contract.
    let ghostGroupId = UUID()
    let stranded = Account(
      id: UUID(), name: "S", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      groupId: ghostGroupId)
    let items = SidebarOutlineItem.tree(
      accounts: Accounts(from: [stranded]), groups: []
    )
    let current = try #require(items.first?.children)
    #expect(current.count == 1)
    #expect(current[0].kind == .account(stranded.id))
  }
}
