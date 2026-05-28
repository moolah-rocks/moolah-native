#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  /// Covers `SidebarOutlineDropCoordinator.target(forProposedItem:childIndex:dragged:accounts:groups:)`.
  /// Pure value tests: assert the `(proposedItem, childIndex, dragged)`
  /// triple translates to the expected `SidebarDropTarget` (or `nil`
  /// when the proposed item isn't a drop surface).
  @Suite("SidebarOutlineDropCoordinator — target translation")
  struct SidebarOutlineDropCoordinatorTargetTests {
    private typealias Support = SidebarOutlineDropCoordinatorTestSupport

    private func draggedAccount() -> DraggableSidebarItem {
      DraggableSidebarItem(kind: .account, id: UUID())
    }

    @Test("nil proposed item with drop-on sentinel returns nil")
    func nilProposedItemDropOn() {
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: nil,
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: draggedAccount(),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("section .earmarks rejects (returns nil)")
    func sectionEarmarksRejects() {
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .section(.earmarks),
        childIndex: 0,
        dragged: draggedAccount(),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("section .current at childIndex N translates to root drop with childIndex N")
    func sectionCurrentRootDrop() {
      let dragged = draggedAccount()
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .section(.current),
        childIndex: 2,
        dragged: dragged,
        accounts: Accounts(from: []),
        groups: [])
      #expect(result?.dragged == dragged)
      #expect(result?.into == nil)
      #expect(result?.childIndex == 2)
    }

    @Test("section .investments at childIndex N translates to root drop with childIndex N")
    func sectionInvestmentsRootDrop() {
      let dragged = draggedAccount()
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .section(.investments),
        childIndex: 0,
        dragged: dragged,
        accounts: Accounts(from: []),
        groups: [])
      #expect(result?.into == nil)
      #expect(result?.childIndex == 0)
    }

    @Test("account row with drop-on sentinel translates to into=.account, childIndex=nil")
    func accountDropOn() {
      let account = Support.bankAccount(name: "T", position: 0)
      let dragged = draggedAccount()
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .account(account.id),
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: dragged,
        accounts: Accounts(from: [account]),
        groups: [])
      #expect(result?.into == .account(account.id))
      #expect(result?.childIndex == nil)
    }

    @Test("account row with childIndex N translates to into=.account, childIndex=N")
    func accountReorderHint() {
      let account = Support.bankAccount(name: "T", position: 0)
      let dragged = draggedAccount()
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .account(account.id),
        childIndex: 3,
        dragged: dragged,
        accounts: Accounts(from: [account]),
        groups: [])
      #expect(result?.into == .account(account.id))
      #expect(result?.childIndex == 3)
    }

    @Test("group row with drop-on sentinel translates to into=.group, childIndex=nil")
    func groupDropOn() {
      let group = Support.currentGroup(position: 0)
      let dragged = draggedAccount()
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .group(group.id),
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: dragged,
        accounts: Accounts(from: []),
        groups: [group])
      #expect(result?.into == .group(group.id))
      #expect(result?.childIndex == nil)
    }

    @Test("group row with childIndex N translates to into=.group, childIndex=N")
    func groupMemberSlot() {
      let group = Support.currentGroup(position: 0)
      let dragged = draggedAccount()
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .group(group.id),
        childIndex: 1,
        dragged: dragged,
        accounts: Accounts(from: []),
        groups: [group])
      #expect(result?.into == .group(group.id))
      #expect(result?.childIndex == 1)
    }

    @Test("earmark row rejects (returns nil)")
    func earmarkRowRejects() {
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .earmark(UUID()),
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: draggedAccount(),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("navigation row rejects (returns nil)")
    func navigationRowRejects() {
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .navigation(.analysis),
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: draggedAccount(),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }

    @Test("total row rejects (returns nil)")
    func totalRowRejects() {
      let result = SidebarOutlineDropCoordinator.target(
        forProposedItem: .total(.netWorth),
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: draggedAccount(),
        accounts: Accounts(from: []),
        groups: [])
      #expect(result == nil)
    }
  }
#endif
