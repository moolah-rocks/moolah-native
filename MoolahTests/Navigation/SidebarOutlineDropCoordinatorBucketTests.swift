#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  /// Covers `SidebarOutlineDropCoordinator.bucket(forProposedItem:accounts:groups:)`.
  /// Pure value tests: each test sets up a hand-built `Accounts` /
  /// `[AccountGroup]` snapshot and asserts the inferred bucket for
  /// each `SidebarRow` case.
  @Suite("SidebarOutlineDropCoordinator — bucket inference")
  struct SidebarOutlineDropCoordinatorBucketTests {
    private typealias Support = SidebarOutlineDropCoordinatorTestSupport

    @Test("nil proposed item infers no bucket")
    func nilProposedItem() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: nil, accounts: Accounts(from: []), groups: [])
      #expect(result == nil)
    }

    @Test("section .current infers .current bucket")
    func sectionCurrent() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .section(.current),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == .current)
    }

    @Test("section .investments infers .investments bucket")
    func sectionInvestments() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .section(.investments),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == .investments)
    }

    @Test("section .earmarks infers no bucket (not a drop target)")
    func sectionEarmarks() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .section(.earmarks),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("section .totals infers no bucket")
    func sectionTotals() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .section(.totals),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("section .navigation infers no bucket")
    func sectionNavigation() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .section(.navigation),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("account row infers the account's bucket — current")
    func accountCurrent() {
      let account = Support.bankAccount(name: "A", position: 0)
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .account(account.id),
        accounts: Accounts(from: [account]),
        groups: [])
      #expect(result == .current)
    }

    @Test("account row infers the account's bucket — investments")
    func accountInvestments() {
      let account = Support.investmentAccount(name: "A", position: 0)
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .account(account.id),
        accounts: Accounts(from: [account]),
        groups: [])
      #expect(result == .investments)
    }

    @Test("group row infers the group's bucket")
    func groupBucket() {
      let group = Support.investmentGroup(position: 0)
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .group(group.id),
        accounts: Accounts(from: []),
        groups: [group])
      #expect(result == .investments)
    }

    @Test("unknown account id infers no bucket")
    func unknownAccount() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .account(UUID()),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("unknown group id infers no bucket")
    func unknownGroup() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .group(UUID()),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("earmark row infers no bucket (not a drop target)")
    func earmarkRow() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .earmark(UUID()),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("total row infers no bucket")
    func totalRow() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .total(.currentTotal),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("navigation row infers no bucket")
    func navigationRow() {
      let result = SidebarOutlineDropCoordinator.bucket(
        forProposedItem: .navigation(.analysis),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }
  }
#endif
