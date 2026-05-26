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
}
