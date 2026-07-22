#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("Sidebar outline update tracking")
  @MainActor
  struct SidebarOutlineUpdateTrackerTests {
    @Test("Unchanged sidebar content does not request another full reload")
    func unchangedContentDoesNotReload() {
      let content = SidebarOutlineContent(
        snapshot: snapshot(), editingRowId: nil)
      let tracker = SidebarOutlineUpdateTracker()

      #expect(tracker.requiresDataReload(for: content))
      #expect(!tracker.requiresDataReload(for: content))
    }

    @Test("Changed sidebar content requests a full reload")
    func changedContentReloads() {
      let initial = SidebarOutlineContent(
        snapshot: snapshot(), editingRowId: nil)
      let changed = SidebarOutlineContent(
        snapshot: snapshot(unreviewedBadgeCount: 1), editingRowId: nil)
      let tracker = SidebarOutlineUpdateTracker()

      #expect(tracker.requiresDataReload(for: initial))
      #expect(tracker.requiresDataReload(for: changed))
    }

    private func snapshot(
      unreviewedBadgeCount: Int = 0
    ) -> SidebarRowTree.Snapshot {
      SidebarRowTree.Snapshot(
        accounts: Accounts(from: []),
        groups: [],
        earmarks: [],
        currentTotal: nil,
        investmentTotal: nil,
        earmarkedTotal: nil,
        netWorth: nil,
        showHidden: false,
        unreviewedBadgeCount: unreviewedBadgeCount)
    }
  }
#endif
