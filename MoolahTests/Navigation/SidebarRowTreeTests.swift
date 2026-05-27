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

  // MARK: - Earmarks

  @Test("Earmarks section lists earmarks in their incoming order")
  func earmarksOrder() {
    let holiday = Earmark(name: "Holiday", instrument: .AUD)
    let tax = Earmark(name: "Tax", instrument: .AUD)
    let tree = SidebarRowTree.build(from: snapshot(earmarks: [holiday, tax]))
    #expect(
      tree.children(of: .section(.earmarks))
        == [.earmark(holiday.id), .earmark(tax.id)])
  }

  // MARK: - Totals

  @Test("Totals section is empty when all summary values are nil")
  func totalsAbsentWhenNil() {
    let tree = SidebarRowTree.build(from: snapshot())
    #expect(tree.children(of: .section(.totals)).isEmpty)
  }

  @Test("Current Total renders as trailing row inside Current Accounts section")
  func currentTotalUnderCurrentSection() {
    let account = Account(name: "Checking", type: .bank, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(
      from: snapshot(accounts: [account], currentTotal: Self.testAmount))
    #expect(
      tree.children(of: .section(.current))
        == [.account(account.id), .total(.currentTotal)])
    #expect(!tree.children(of: .section(.totals)).contains(.total(.currentTotal)))
  }

  @Test("Investment Total renders as trailing row inside Investments section")
  func investmentTotalUnderInvestmentsSection() {
    let account = Account(name: "Brokerage", type: .investment, instrument: .AUD, position: 0)
    let tree = SidebarRowTree.build(
      from: snapshot(accounts: [account], investmentTotal: Self.testAmount))
    #expect(
      tree.children(of: .section(.investments))
        == [.account(account.id), .total(.investmentTotal)])
    #expect(!tree.children(of: .section(.totals)).contains(.total(.investmentTotal)))
  }

  @Test("Earmarked Total renders as trailing row inside Earmarks section")
  func earmarkedTotalUnderEarmarksSection() {
    let earmark = Earmark(name: "Holiday", instrument: .AUD)
    let tree = SidebarRowTree.build(
      from: snapshot(earmarks: [earmark], earmarkedTotal: Self.testEarmarked))
    #expect(
      tree.children(of: .section(.earmarks))
        == [.earmark(earmark.id), .total(.earmarkedTotal)])
    #expect(!tree.children(of: .section(.totals)).contains(.total(.earmarkedTotal)))
  }

  @Test("Net Worth renders in the implicit Totals section")
  func netWorthInTotalsSection() {
    let tree = SidebarRowTree.build(from: snapshot(netWorth: Self.testAmount))
    #expect(tree.children(of: .section(.totals)) == [.total(.netWorth)])
  }

  @Test("Per-bucket totals are absent when their backing amount is nil")
  func perBucketTotalsHiddenWhenNil() {
    let bank = Account(name: "Checking", type: .bank, instrument: .AUD, position: 0)
    let brokerage = Account(name: "Brokerage", type: .investment, instrument: .AUD, position: 0)
    let earmark = Earmark(name: "Holiday", instrument: .AUD)
    let tree = SidebarRowTree.build(
      from: snapshot(accounts: [bank, brokerage], earmarks: [earmark]))
    #expect(tree.children(of: .section(.current)) == [.account(bank.id)])
    #expect(tree.children(of: .section(.investments)) == [.account(brokerage.id)])
    #expect(tree.children(of: .section(.earmarks)) == [.earmark(earmark.id)])
  }

  @Test("Available Funds appears in Totals section only when earmarked is positive")
  func availableFundsGating() {
    let withAvailable = SidebarRowTree.build(
      from: snapshot(
        currentTotal: Self.testAmount, earmarkedTotal: Self.testEarmarked))
    #expect(
      withAvailable.children(of: .section(.totals))
        .contains(.total(.availableFunds)))

    let zeroEarmark = SidebarRowTree.build(
      from: snapshot(
        currentTotal: Self.testAmount,
        earmarkedTotal: .zero(instrument: .AUD)))
    #expect(
      !zeroEarmark.children(of: .section(.totals))
        .contains(.total(.availableFunds)))
  }

  // MARK: - Navigation

  @Test("Navigation children are the fixed-order set of nav kinds")
  func navigationOrder() {
    let tree = SidebarRowTree.build(from: snapshot())
    #expect(
      tree.children(of: .section(.navigation)) == [
        .navigation(.analysis),
        .navigation(.reports),
        .navigation(.categories),
        .navigation(.upcoming),
        .navigation(.recentlyAdded),
        .navigation(.allTransactions),
      ])
  }

  // MARK: - Helpers

  private static let testAmount = InstrumentAmount(quantity: 100, instrument: .AUD)
  private static let testEarmarked = InstrumentAmount(quantity: 50, instrument: .AUD)

  private func snapshot(
    accounts: [Account] = [],
    groups: [AccountGroup] = [],
    earmarks: [Earmark] = [],
    currentTotal: InstrumentAmount? = nil,
    investmentTotal: InstrumentAmount? = nil,
    earmarkedTotal: InstrumentAmount? = nil,
    netWorth: InstrumentAmount? = nil,
    showHidden: Bool = false
  ) -> SidebarRowTree.Snapshot {
    SidebarRowTree.Snapshot(
      accounts: Accounts(from: accounts),
      groups: groups,
      earmarks: earmarks,
      currentTotal: currentTotal,
      investmentTotal: investmentTotal,
      earmarkedTotal: earmarkedTotal,
      netWorth: netWorth,
      showHidden: showHidden,
      unreviewedBadgeCount: 0)
  }
}
