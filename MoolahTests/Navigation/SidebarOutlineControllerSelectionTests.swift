import Testing

@testable import Moolah

#if os(macOS)
  import AppKit

  @MainActor
  @Suite("Sidebar outline selection reconciliation")
  struct SidebarOutlineControllerSelectionTests {
    @Test
    func programmaticSelectionDoesNotEchoThroughBinding() {
      let controller = SidebarOutlineController()
      _ = controller.view
      let tree = SidebarRowTree.build(
        from: SidebarRowTree.Snapshot(
          accounts: Accounts(from: []),
          groups: [],
          earmarks: [],
          currentTotal: nil,
          investmentTotal: nil,
          earmarkedTotal: nil,
          netWorth: nil,
          showHidden: false,
          unreviewedBadgeCount: 0))
      var emittedSelections: [SidebarSelection?] = []
      controller.delegate.selectionChanged = { row in
        emittedSelections.append(row?.asSelection)
      }

      controller.apply(
        tree: tree,
        expandedGroupIds: [],
        selection: .allTransactions,
        reloadData: true)

      #expect(emittedSelections.isEmpty)
    }

    @Test
    func selectionCallbacksResumeAfterReconciliation() {
      let controller = SidebarOutlineController()
      _ = controller.view
      let tree = SidebarRowTree.build(
        from: SidebarRowTree.Snapshot(
          accounts: Accounts(from: []),
          groups: [],
          earmarks: [],
          currentTotal: nil,
          investmentTotal: nil,
          earmarkedTotal: nil,
          netWorth: nil,
          showHidden: false,
          unreviewedBadgeCount: 0))

      controller.apply(
        tree: tree,
        expandedGroupIds: [],
        selection: .allTransactions,
        reloadData: true)

      var emittedSelections: [SidebarSelection?] = []
      controller.delegate.selectionChanged = { row in
        emittedSelections.append(row?.asSelection)
      }
      controller.delegate.outlineViewSelectionDidChange(
        Notification(
          name: NSOutlineView.selectionDidChangeNotification,
          object: controller.outlineView))

      #expect(emittedSelections == [.allTransactions])
    }
  }
#endif
