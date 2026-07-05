import XCTest

/// macOS-only XCUITest covering inline rename on the unified sidebar
/// (account, earmark, account-group rows) via all three triggers
/// (context-menu Rename, Return key, double-click). All tests use the
/// `.tradeBaseline` seed which ships with a rename-target earmark
/// and group fixture in addition to the standard accounts.
final class SidebarInlineRenameMacTests: MoolahUITestCase {
  func testContextMenuRenameAccount() {
    let app = launch(seed: .tradeBaseline)
    let renamed = "Checking Renamed"

    app.sidebar.beginRenameAccount(.checking)
    app.sidebar.typeRenameAndCommit(renamed)

    // The sidebar row's accessibility label includes the account name;
    // the new label materialising is the post-condition.
    app.sidebar.expectAccountLabel(.checking, contains: renamed)
  }

  func testContextMenuRenameEarmark() {
    let app = launch(seed: .tradeBaseline)
    let renamed = "Holiday Renamed"

    app.sidebar.beginRenameEarmark(.renameTarget)
    app.sidebar.typeRenameAndCommit(renamed)

    app.sidebar.expectEarmarkLabel(.renameTarget, contains: renamed)
  }

  func testContextMenuRenameGroup() {
    let app = launch(seed: .tradeBaseline)
    let renamed = "Investments Renamed"

    app.sidebar.beginRenameGroup(.renameTarget)
    app.sidebar.typeRenameAndCommit(renamed)

    app.sidebar.expectGroupLabel(.renameTarget, contains: renamed)
  }

  func testReturnKeyEntersRename() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.selectAndPressReturn(.checking)
    app.sidebar.expectRenameFieldVisible()

    // Cancel so nothing is committed.
    app.sidebar.cancelRename()
  }

  func testEscapeCancelsRename() {
    let app = launch(seed: .tradeBaseline)
    let account = SidebarAccount.checking
    let originalName = UITestFixtures.TradeBaseline.checkingAccountName

    // Enter rename via the Return trigger (setup), then cancel with Esc.
    app.sidebar.selectAndPressReturn(account)
    app.sidebar.cancelRename()
    app.sidebar.expectRenameFieldGone()

    // Esc leaves the account name unchanged.
    app.sidebar.expectAccountLabel(account, contains: originalName)
  }

  func testDoubleClickAccountNameEntersRename() {
    let app = launch(seed: .tradeBaseline)
    let account = SidebarAccount.checking

    app.sidebar.doubleClickAccountName(account)
    app.sidebar.expectRenameFieldVisible()

    // Cancel so the seed is left unchanged.
    app.sidebar.cancelRename()
  }
}
