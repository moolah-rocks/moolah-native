import XCTest

extension SidebarScreen {
  // MARK: - Row label / visibility expectations

  /// Asserts the account row's accessibility label contains `text`,
  /// waiting up to 10s. The sidebar row's label embeds the account name,
  /// so this is the post-condition for a rename landing (or, with the
  /// original name, for a cancelled rename leaving the label unchanged).
  func expectAccountLabel(_ account: SidebarAccount, contains text: String) {
    Trace.record(detail: "account=\(account) text=\(text)")
    expectRowLabel(
      UITestIdentifiers.Sidebar.account(account.id),
      contains: text,
      subject: "account \(account)")
  }

  /// Asserts the earmark row's accessibility label contains `text`,
  /// waiting up to 10s. Post-condition for an earmark rename landing.
  func expectEarmarkLabel(_ earmark: SidebarEarmark, contains text: String) {
    Trace.record(detail: "earmark=\(earmark) text=\(text)")
    expectRowLabel(
      UITestIdentifiers.Sidebar.earmark(earmark.id),
      contains: text,
      subject: "earmark \(earmark)")
  }

  /// Asserts the group row's accessibility label contains `text`,
  /// waiting up to 10s. Post-condition for a group rename landing.
  func expectGroupLabel(_ group: SidebarGroup, contains text: String) {
    Trace.record(detail: "group=\(group) text=\(text)")
    expectRowLabel(
      UITestIdentifiers.Sidebar.group(group.id),
      contains: text,
      subject: "group \(group)")
  }

  /// Asserts the account row is present in the sidebar, waiting up to 10s.
  /// Post-condition for `dragAccount(_:ontoGroup:)`: the dragged row stays
  /// in the tree (now as a group member) rather than unmounting.
  func expectAccountVisible(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    if !app.element(for: identifier).waitForExistence(timeout: 10) {
      Trace.recordFailure("sidebar row '\(identifier)' not present")
      XCTFail("Sidebar row for account \(account) was not present within 10s")
    }
  }

  /// Asserts the group row disappears from the sidebar, waiting up to 10s.
  /// Post-condition for a group auto-deleting once its last member is
  /// dragged out.
  func expectGroupGone(_ group: SidebarGroup) {
    Trace.record(detail: "group=\(group)")
    let identifier = UITestIdentifiers.Sidebar.group(group.id)
    let row = app.element(for: identifier)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: row)
    if XCTWaiter.wait(for: [expectation], timeout: 10) != .completed {
      Trace.recordFailure("sidebar row '\(identifier)' still present")
      XCTFail("Sidebar row for group \(group) was still present after 10s")
    }
  }

  // MARK: - Private helpers

  /// Waits up to 10s for the row at `identifier` to carry an accessibility
  /// label containing `text`. Shared by the account/earmark/group label
  /// expectations; `subject` names the entity in the failure message.
  private func expectRowLabel(
    _ identifier: String, contains text: String, subject: String
  ) {
    let row = app.element(for: identifier)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", text), object: row)
    if XCTWaiter.wait(for: [expectation], timeout: 10) != .completed {
      Trace.recordFailure("row '\(identifier)' label did not contain '\(text)'")
      XCTFail(
        "Sidebar row for \(subject) did not reflect label containing '\(text)' within 10s")
    }
  }
}
