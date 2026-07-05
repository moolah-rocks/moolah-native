import XCTest

extension SidebarScreen {
  // MARK: - Group navigation

  /// Switches the centre column to the given account group's composite
  /// detail (the group's merged, member-scoped transaction list). Clicking
  /// the group row sets `SidebarSelection.group(id)`, which routes to
  /// `AccountDetailView` → a `TransactionListView` scoped to the group's
  /// members. Returns once that list's container is in the accessibility
  /// tree — the same "list re-rendered" post-condition as
  /// `switchToAccount(_:)`.
  func openGroup(_ group: SidebarGroup) {
    Trace.record(#function, detail: "group=\(group)")
    let identifier = UITestIdentifiers.Sidebar.group(group.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for group \(group) did not appear within 10s")
      return
    }
    row.click()

    let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
    if !listContainer.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "transaction list container '\(UITestIdentifiers.TransactionList.container)' "
          + "did not appear after opening group \(group)")
      XCTFail(
        "Transaction list did not render within 10s of opening group \(group)")
    }
  }
}
