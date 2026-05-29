import XCTest

/// XCUITest covering drag-and-drop on the unified macOS sidebar
/// (issue #991). Three scenarios, all using `.tradeBaseline`:
///
/// 1. Drag one standalone account onto another standalone account in
///    the same bucket creates a 2-member group and enters inline-rename
///    mode on the new group's name.
/// 2. Drag a standalone account onto an existing group in the same
///    bucket adds it as a member.
/// 3. Drag a standalone account onto another in the same bucket with
///    source/target reversed — XCUITest's `press(forDuration:thenDragTo:)`
///    centres the drop, which the policy interprets as "drop onto"
///    rather than "reorder between rows", so the observable outcome is
///    the same as scenario 1 (rename field visible on the new group).
///    The pure reorder dispatch is covered by the unit test
///    `SidebarOutlineDropCoordinatorCommitTests.commitReorderRoot`.
///
/// All three test pairs use the investments-bucket fixtures (`.brokerage`,
/// `.tradesBrokerage`, and `SidebarGroup.renameTarget`) because the
/// `.tradeBaseline` seed currently exposes two standalone investments
/// accounts and an investments-bucket group, but only one standalone
/// `.current` account (`.checking`). Drops must stay within a bucket —
/// `SidebarDropPolicy` denies cross-bucket drags silently.
final class SidebarDragAndDropMacTests: MoolahUITestCase {

  func testDragAccountOntoAccountCreatesGroup() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.dragAccount(.tradesBrokerage, ontoAccount: .brokerage)

    // The strongest end-to-end signal is the inline rename field
    // materialising on the new group's row — that exercises the drop,
    // the group creation, and the `onCreatedGroup → editingRowId`
    // callback in one assertion. The group id is non-deterministic so
    // we resolve via the shared `renameNameField` identifier the
    // inline-rename plumbing publishes.
    let renameField = app.element(for: UITestIdentifiers.Sidebar.renameNameField)
    let predicate = NSPredicate(format: "exists == true")
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: renameField)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3),
      .completed,
      "Inline rename TextField did not appear on the new group within 3s")
  }

  func testDragAccountOntoGroupJoinsIt() {
    let app = launch(seed: .tradeBaseline)

    // `.tradesBrokerage` and `SidebarGroup.renameTarget` are both in
    // the investments bucket; the policy permits the drop.
    app.sidebar.dragAccount(.tradesBrokerage, ontoGroup: .renameTarget)

    // Post-condition: the dragged account row remains in the
    // accessibility tree (now as a member of the group). XCUITest cannot
    // observe membership directly; the row's continued existence after
    // the drop, combined with the unit-test coverage of
    // `SidebarDropDispatch.dropOntoGroup`, is the end-to-end signal that
    // the drop landed without crashing or unmounting the row.
    let memberRow = app.element(
      for: UITestIdentifiers.Sidebar.account(SidebarAccount.tradesBrokerage.id))
    let predicate = NSPredicate(format: "exists == true")
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: memberRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3),
      .completed,
      "Dragged account row was not present after the drop within 3s")
  }

  func testDragReordersStandaloneAccounts() {
    let app = launch(seed: .tradeBaseline)

    // Reversed source/target relative to scenario 1: dragging
    // `.brokerage` onto `.tradesBrokerage` exercises the same code path
    // from the opposite direction. Per the scope-note above, the
    // observable outcome is still "group created + rename field visible"
    // because XCUITest's `press(forDuration:thenDragTo:)` always lands
    // the drop on the centre of the target row. The pure reorder branch
    // is covered by
    // `SidebarOutlineDropCoordinatorCommitTests.commitReorderRoot`.
    app.sidebar.dragAccount(.brokerage, ontoAccount: .tradesBrokerage)

    let renameField = app.element(for: UITestIdentifiers.Sidebar.renameNameField)
    let predicate = NSPredicate(format: "exists == true")
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: renameField)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3),
      .completed,
      "Inline rename TextField did not appear on the new group within 3s")
  }

  /// Cross-group drop-onto: drag the sole member of a 1-member group onto
  /// another standalone account in the same bucket. With the dropOnto
  /// dispatch generalised to remove the source from its old group first,
  /// the old group auto-deletes when emptied — its row should disappear
  /// from the sidebar. Built from `.tradeBaseline` without seed
  /// extensions: drag `.brokerage` onto the empty `.renameTarget` group
  /// first to make it a 1-member group, then drag it back out onto
  /// `.tradesBrokerage`.
  func testDragSoleMemberOntoStandaloneDeletesOldGroup() {
    let app = launch(seed: .tradeBaseline)

    // Step 1: populate the empty .renameTarget group with .brokerage.
    app.sidebar.dragAccount(.brokerage, ontoGroup: .renameTarget)
    let brokerageRow = app.element(
      for: UITestIdentifiers.Sidebar.account(SidebarAccount.brokerage.id))
    let brokerageExists = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"), object: brokerageRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [brokerageExists], timeout: 3), .completed,
      "Brokerage row missing after dropping into renameTarget group")

    // Step 2: drag .brokerage (now sole member of .renameTarget) onto
    // .tradesBrokerage. With the new dropOntoAccount path, .renameTarget
    // is emptied + auto-deleted.
    app.sidebar.dragAccount(.brokerage, ontoAccount: .tradesBrokerage)

    // Post-condition: the renameTarget group row disappears.
    let groupRow = app.element(
      for: UITestIdentifiers.Sidebar.group(SidebarGroup.renameTarget.id))
    let groupGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: groupRow)
    XCTAssertEqual(
      XCTWaiter.wait(for: [groupGone], timeout: 3), .completed,
      "renameTarget group row still present 3s after sole member dragged out")
  }
}
