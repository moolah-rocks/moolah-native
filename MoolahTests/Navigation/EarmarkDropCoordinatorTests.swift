#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("SidebarOutlineDropCoordinator — earmark translation")
  struct EarmarkDropCoordinatorTests {
    private let first = Earmark(
      name: "First", instrument: .defaultTestInstrument, position: 0)
    private let second = Earmark(
      name: "Second", instrument: .defaultTestInstrument, position: 1)

    @Test("earmark dropped into its section resolves to a reorder")
    func sectionInsertionResolvesToReorder() {
      let dragged = DraggableSidebarItem(kind: .earmark, id: second.id)

      let outcome = SidebarOutlineDropCoordinator.earmarkOutcome(
        forProposedItem: .section(.earmarks),
        childIndex: 0,
        dragged: dragged,
        earmarks: [first, second])

      #expect(
        outcome
          == .reorderEarmark(sourceId: second.id, insertionIndex: 0))
    }

    @Test("account dropped into the earmark section is denied")
    func accountCannotEnterEarmarks() {
      let outcome = SidebarOutlineDropCoordinator.earmarkOutcome(
        forProposedItem: .section(.earmarks),
        childIndex: 0,
        dragged: DraggableSidebarItem(kind: .account, id: UUID()),
        earmarks: [first, second])

      #expect(outcome == .deny)
    }

    @Test("earmark row insertion hint retargets after that row")
    func rowInsertionRetargetsAfterRow() {
      let outcome = SidebarOutlineDropCoordinator.earmarkOutcome(
        forProposedItem: .earmark(first.id),
        childIndex: 0,
        dragged: DraggableSidebarItem(kind: .earmark, id: second.id),
        earmarks: [first, second])

      #expect(outcome == .retargetEarmarks(insertionIndex: 1))
    }

    @Test("dropping directly onto an earmark row is denied")
    func rowDropOnIsDenied() {
      let outcome = SidebarOutlineDropCoordinator.earmarkOutcome(
        forProposedItem: .earmark(first.id),
        childIndex: NSOutlineViewDropOnItemIndex,
        dragged: DraggableSidebarItem(kind: .earmark, id: second.id),
        earmarks: [first, second])

      #expect(outcome == .deny)
    }

    @Test("unknown earmark source is denied")
    func unknownSourceIsDenied() {
      let outcome = SidebarOutlineDropCoordinator.earmarkOutcome(
        forProposedItem: .section(.earmarks),
        childIndex: 0,
        dragged: DraggableSidebarItem(kind: .earmark, id: UUID()),
        earmarks: [first, second])

      #expect(outcome == .deny)
    }

    @Test("total row is not an earmark drop surface")
    func totalRowIsDenied() {
      let outcome = SidebarOutlineDropCoordinator.earmarkOutcome(
        forProposedItem: .total(.earmarkedTotal),
        childIndex: 0,
        dragged: DraggableSidebarItem(kind: .earmark, id: second.id),
        earmarks: [first, second])

      #expect(outcome == .deny)
    }
  }
#endif
