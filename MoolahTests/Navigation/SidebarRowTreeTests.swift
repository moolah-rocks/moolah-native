import Foundation
import Testing

@testable import Moolah

@Suite("SidebarRowTree — accounts")
struct SidebarRowTreeTests {
  @Test("One current bank account: section header + one account leaf")
  func singleCurrentAccount() {
    let account = Account(name: "Checking", type: .bank, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(from: snapshot(accounts: [account]))

    #expect(tree.roots.contains(.section(.current)))
    #expect(tree.children(of: .section(.current)) == [.account(account.id)])
    #expect(!tree.isExpandable(.account(account.id)))
  }

  @Test("Investment account lands under .investments section, not .current")
  func investmentAccountRouted() {
    let account = Account(name: "Brokerage", type: .investment, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(from: snapshot(accounts: [account]))

    #expect(tree.children(of: .section(.current)).isEmpty)
    #expect(tree.children(of: .section(.investments)) == [.account(account.id)])
  }

  @Test("Group with two members: group row + two child account rows")
  func groupWithMembers() {
    let groupId = UUID()
    let firstMember = Account(
      name: "Cash", type: .bank, instrument: .AUD, position: 0, groupId: groupId)
    let secondMember = Account(
      name: "Savings", type: .bank, instrument: .AUD, position: 1, groupId: groupId)
    let group = AccountGroup(
      id: groupId, name: "Trust", bucket: .current, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(
      from: snapshot(accounts: [firstMember, secondMember], groups: [group]))

    #expect(tree.children(of: .section(.current)) == [.group(groupId)])
    #expect(
      tree.children(of: .group(groupId))
        == [.account(firstMember.id), .account(secondMember.id)])
  }

  @Test("Hidden account excluded when showHidden=false; included when true")
  func hiddenAccountFilter() {
    var hidden = Account(name: "Old", type: .bank, instrument: .AUD, position: 0)
    hidden.isHidden = true
    let visible = Account(name: "Active", type: .bank, instrument: .AUD, position: 1)
    let accounts = [hidden, visible]

    let hidingTree = SidebarRowTree.build(from: snapshot(accounts: accounts))
    #expect(hidingTree.children(of: .section(.current)) == [.account(visible.id)])

    let showingTree = SidebarRowTree.build(
      from: snapshot(accounts: accounts, showHidden: true))
    #expect(
      showingTree.children(of: .section(.current))
        == [.account(hidden.id), .account(visible.id)])
  }

  @Test("Empty group is not expandable — no disclosure triangle")
  func emptyGroupIsNotExpandable() {
    let groupId = UUID()
    let group = AccountGroup(
      id: groupId, name: "Empty", bucket: .current, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(from: snapshot(accounts: [], groups: [group]))

    #expect(!tree.isExpandable(.group(groupId)))
    #expect(tree.children(of: .group(groupId)).isEmpty)
  }

  // MARK: - Helpers

  private func snapshot(
    accounts: [Account],
    groups: [AccountGroup] = [],
    showHidden: Bool = false
  ) -> SidebarRowTree.Snapshot {
    SidebarRowTree.Snapshot(
      accounts: Accounts(from: accounts),
      groups: groups,
      earmarks: [],
      currentTotal: nil,
      investmentTotal: nil,
      earmarkedTotal: nil,
      netWorth: nil,
      showHidden: showHidden,
      unreviewedBadgeCount: 0)
  }
}
