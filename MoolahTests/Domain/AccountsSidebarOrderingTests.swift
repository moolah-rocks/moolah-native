import Foundation
import Testing

@testable import Moolah

@Suite("Accounts sidebar ordering")
struct AccountsSidebarOrderingTests {
  private func bank(_ name: String, position: Int, isHidden: Bool = false) -> Account {
    Account(
      id: UUID(), name: name, type: .bank, instrument: .AUD,
      positions: [], position: position, isHidden: isHidden)
  }
  private func investment(_ name: String, position: Int, isHidden: Bool = false) -> Account {
    Account(
      id: UUID(), name: name, type: .investment, instrument: .AUD,
      positions: [], position: position, isHidden: isHidden)
  }

  @Test("Partitions current vs investment by type")
  func partitionsByType() {
    let chequing = bank("Chequing", position: 0)
    let house = Account(
      id: UUID(), name: "House", type: .asset, instrument: .AUD,
      positions: [], position: 1, isHidden: false)
    let card = Account(
      id: UUID(), name: "Card", type: .creditCard, instrument: .AUD,
      positions: [], position: 2, isHidden: false)
    let brokerage = investment("Brokerage", position: 0)
    let accounts = Accounts(from: [brokerage, card, chequing, house])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["Chequing", "House", "Card"])
    #expect(groups.investments.map(\.name) == ["Brokerage"])
  }

  @Test("Crypto wallets land in the investments bucket")
  func cryptoWalletsGroupedAsInvestment() {
    let chequing = bank("Chequing", position: 0)
    let brokerage = investment("Brokerage", position: 0)
    let wallet = Account(
      id: UUID(), name: "ETH Wallet", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let accounts = Accounts(from: [brokerage, chequing, wallet])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["Chequing"])
    #expect(groups.investments.map(\.name) == ["Brokerage", "ETH Wallet"])
  }

  @Test("Sorts within each group by position ascending")
  func sortsByPosition() {
    let acct1 = bank("A", position: 2)
    let acct2 = bank("B", position: 0)
    let acct3 = bank("C", position: 1)
    let accounts = Accounts(from: [acct1, acct2, acct3])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["B", "C", "A"])
  }

  @Test("Excluding drops the matching account from both helpers")
  func excludingDrops() {
    let first = bank("A", position: 0)
    let second = bank("B", position: 1)
    let accounts = Accounts(from: [first, second])

    let groups = accounts.sidebarGrouped(excluding: first.id)
    let flat = accounts.sidebarOrdered(excluding: first.id)

    #expect(groups.current.map(\.name) == ["B"])
    #expect(flat.map(\.name) == ["B"])
  }

  @Test("Hidden accounts are filtered out by default")
  func hiddenFiltered() {
    let visible = bank("Visible", position: 0)
    let hidden = bank("Hidden", position: 1, isHidden: true)
    let accounts = Accounts(from: [visible, hidden])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["Visible"])
  }

  @Test("alwaysInclude retains a hidden account")
  func alwaysIncludeRetainsHidden() {
    let visible = bank("Visible", position: 0)
    let hidden = bank("Hidden", position: 1, isHidden: true)
    let accounts = Accounts(from: [visible, hidden])

    let groups = accounts.sidebarGrouped(alwaysInclude: hidden.id)

    #expect(groups.current.map(\.name) == ["Visible", "Hidden"])
  }

  @Test("alwaysInclude on a non-existent id is a no-op")
  func alwaysIncludeNonExistent() {
    let visible = bank("Visible", position: 0)
    let accounts = Accounts(from: [visible])

    let groups = accounts.sidebarGrouped(alwaysInclude: UUID())

    #expect(groups.current.map(\.name) == ["Visible"])
  }

  @Test("excluding wins over alwaysInclude when they collide")
  func excludingWinsOverAlwaysInclude() {
    // Defensive contract: callers can pass the picker's own from-account
    // as `excluding` and the same id as `alwaysInclude` (the current
    // selection). Exclusion must win so a transfer's from-account never
    // reappears as a counterpart option.
    let only = bank("A", position: 0)
    let accounts = Accounts(from: [only])

    let groups = accounts.sidebarGrouped(excluding: only.id, alwaysInclude: only.id)

    #expect(groups.current.isEmpty)
  }

  @Test("sidebarOrdered concatenates current then investment")
  func flatOrder() {
    let chequing = bank("Chequing", position: 0)
    let brokerage = investment("Brokerage", position: 0)
    let accounts = Accounts(from: [brokerage, chequing])

    #expect(accounts.sidebarOrdered().map(\.name) == ["Chequing", "Brokerage"])
  }

  // MARK: - groupAwareSidebar(groups:)

  @Test("groupAwareSidebar with no groups returns standalone-only entries")
  func groupAwareNoGroups() {
    let chequing = bank("Chequing", position: 0)
    let brokerage = investment("Brokerage", position: 0)
    let accounts = Accounts(from: [chequing, brokerage])

    let result = accounts.groupAwareSidebar(groups: [])

    #expect(result.current == [.account(chequing)])
    #expect(result.investments == [.account(brokerage)])
  }

  @Test("groupAwareSidebar collects members by groupId and sorts by member position")
  func groupAwareMembersSorted() {
    let group = AccountGroup(
      name: "Crypto", bucket: .investments, instrument: .AUD, position: 0)
    let memberB = Account(
      id: UUID(), name: "B", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "b", count: 40), chainId: 1,
      groupId: group.id)
    let memberA = Account(
      id: UUID(), name: "A", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1,
      groupId: group.id)
    let accounts = Accounts(from: [memberA, memberB])

    let result = accounts.groupAwareSidebar(groups: [group])

    guard case .group(let observedGroup, let observedMembers) = result.investments.first else {
      Issue.record("expected single group entry")
      return
    }
    #expect(observedGroup.id == group.id)
    #expect(observedMembers.map(\.name) == ["A", "B"])
  }

  @Test("hidden members are excluded from the group's members array")
  func groupAwareHiddenMemberExcluded() {
    let group = AccountGroup(
      name: "Crypto", bucket: .investments, instrument: .AUD, position: 0)
    let hidden = Account(
      id: UUID(), name: "Hidden", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: true,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1,
      groupId: group.id)
    let visible = Account(
      id: UUID(), name: "Visible", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "b", count: 40), chainId: 1,
      groupId: group.id)
    let accounts = Accounts(from: [hidden, visible])

    let result = accounts.groupAwareSidebar(groups: [group])

    guard case .group(_, let members) = result.investments.first else {
      Issue.record("expected single group entry")
      return
    }
    #expect(members.map(\.name) == ["Visible"])
  }

  @Test("standalone accounts and groups intermix by position")
  func groupAwareIntermixedByPosition() {
    let group = AccountGroup(
      name: "Crypto", bucket: .investments, instrument: .AUD, position: 1)
    let standalone0 = investment("ETF-zero", position: 0)
    let standalone2 = investment("ETF-two", position: 2)
    let accounts = Accounts(from: [standalone0, standalone2])

    let result = accounts.groupAwareSidebar(groups: [group])

    // standalone(0), group(1), standalone(2)
    #expect(result.investments.count == 3)
    if case .account(let account) = result.investments[0] {
      #expect(account.name == "ETF-zero")
    } else {
      Issue.record("expected ETF-zero first")
    }
    if case .group(let observed, _) = result.investments[1] {
      #expect(observed.name == "Crypto")
    } else {
      Issue.record("expected Crypto group second")
    }
    if case .account(let account) = result.investments[2] {
      #expect(account.name == "ETF-two")
    } else {
      Issue.record("expected ETF-two third")
    }
  }

  @Test("equal positions tie-break account-first")
  func groupAwareTieBreakAccountFirst() {
    let group = AccountGroup(
      name: "Crypto", bucket: .investments, instrument: .AUD, position: 0)
    let standalone = investment("ETF", position: 0)
    let accounts = Accounts(from: [standalone])

    let result = accounts.groupAwareSidebar(groups: [group])

    // standalone first, group second
    if case .account(let account) = result.investments[0] {
      #expect(account.name == "ETF")
    } else {
      Issue.record("expected ETF first on tie")
    }
    if case .group(let observed, _) = result.investments[1] {
      #expect(observed.name == "Crypto")
    } else {
      Issue.record("expected Crypto group second on tie")
    }
  }

  @Test("groups appear only in their declared bucket")
  func groupAwareCrossBucketIsolation() {
    let currentGroup = AccountGroup(
      name: "Joint", bucket: .current, instrument: .AUD, position: 0)
    let investmentGroup = AccountGroup(
      name: "Stocks", bucket: .investments, instrument: .AUD, position: 0)
    let accounts = Accounts(from: [])

    let result = accounts.groupAwareSidebar(groups: [currentGroup, investmentGroup])

    if case .group(let observed, _) = result.current.first {
      #expect(observed.name == "Joint")
    } else {
      Issue.record("expected Joint group in current bucket")
    }
    if case .group(let observed, _) = result.investments.first {
      #expect(observed.name == "Stocks")
    } else {
      Issue.record("expected Stocks group in investments bucket")
    }
  }

  @Test("account with dangling groupId renders as standalone in its bucket")
  func groupAwareOrphanedGroupId() {
    // Sync delivery can place an Account ahead of its AccountGroup
    // (spec §"Sync & schema"). The unknown id resolves to standalone
    // until the group arrives — never to "invisible". This matches
    // the same dangling-reference tolerance the Category lookup uses.
    let orphan = Account(
      id: UUID(), name: "Orphan", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      groupId: UUID())  // points at no group
    let accounts = Accounts(from: [orphan])

    let result = accounts.groupAwareSidebar(groups: [])

    #expect(result.current == [.account(orphan)])
  }
}
