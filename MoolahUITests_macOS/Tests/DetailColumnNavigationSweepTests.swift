import XCTest

/// Smoke test for navigation across heterogeneous detail-column leaves.
///
/// This sweep does not reproduce the AppKit toolbar bridge crash
/// (`NSInternalInconsistencyException: NSToolbar already contains an
/// item with the identifier com.apple.SwiftUI.search`) that fires when
/// SwiftUI re-mounts a `.searchable` / `.toolbar`-bearing leaf while
/// the previous leaf's registration is still live: the crash fires
/// during sub-second navigation in production, but XCUITest's natural
/// `waitForExistence` pacing (~1-2 s per click) is too slow to surface
/// the race deterministically — the sweep takes ~110 s end to end and
/// never reproduces. So this test serves a different role:
///
/// **As a navigation smoke test**, it catches accidental regressions
/// to the navigation graph: a missing `accessibilityIdentifier`, a
/// removed `SidebarSelection` case, a leaf view that fails to render
/// the transaction-list container after a sidebar selection. Those
/// kinds of breakage would silently land otherwise.
///
/// **The toolbar bridge bug itself** is fixed by the per-leaf
/// `NavigationStack { … }.id(selection)` wrap in `ContentView.detail`
/// (see `guides/UI_GUIDE.md` §3) and verified by manual sweep per the
/// per-PR verification matrix. Don't expect this test to fail on a
/// regression of that fix — only manual sweeping reproduces the race
/// in a reasonable time budget.
@MainActor
final class DetailColumnNavigationSweepTests: MoolahUITestCase {
  func testNavigationSweepAcrossDetailLeavesLandsCleanly() {
    let app = launch(seed: .tradeBaseline)
    let sidebar = app.sidebar

    // One cycle of eight selections is enough to confirm every named
    // sidebar item routes to a renderable leaf. Multiple cycles were
    // tried and added ~20 s/cycle of CI time without catching anything
    // additional — XCUITest's pacing makes it useless for the
    // toolbar-bridge race regardless of cycle count.
    sidebar.switchToAccount(.checking)
    sidebar.switchToAccount(.brokerage)
    sidebar.switchToNamed(.upcoming)
    sidebar.switchToAccount(.tradesBrokerage)
    sidebar.switchToNamed(.allTransactions)
    sidebar.switchToNamed(.analysis)
    sidebar.switchToAccount(.checking)
    sidebar.switchToNamed(.recentlyAdded)

    // Land on a transaction list and confirm the container is in the
    // accessibility tree. Catches a silent "leaf renders empty" regression.
    sidebar.switchToAccount(.checking)
    app.transactionList.expectContainerVisible()
  }
}
