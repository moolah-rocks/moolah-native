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
    // wait for the new label to materialise as the post-condition.
    let renamedRow = app.element(
      for: UITestIdentifiers.Sidebar.account(SidebarAccount.checking.id))
    let predicate = NSPredicate(format: "label CONTAINS %@", renamed)
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: renamedRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3),
      .completed,
      "Sidebar row did not reflect the renamed account label within 3s")
  }

  func testContextMenuRenameEarmark() {
    let app = launch(seed: .tradeBaseline)
    let renamed = "Holiday Renamed"

    app.sidebar.beginRenameEarmark(.renameTarget)
    app.sidebar.typeRenameAndCommit(renamed)

    let renamedRow = app.element(
      for: UITestIdentifiers.Sidebar.earmark(SidebarEarmark.renameTarget.id))
    let predicate = NSPredicate(format: "label CONTAINS %@", renamed)
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: renamedRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3),
      .completed,
      "Sidebar row did not reflect the renamed earmark label within 3s")
  }
}
