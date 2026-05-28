import XCTest

/// Symbolic reference to a sidebar account. Tests reference accounts by
/// name; the driver maps each case to the seeded UUID.
enum SidebarAccount {
  case checking
  case brokerage
  /// `.tradeBaseline`'s second investment account: `.calculatedFromTrades`
  /// mode with no `InvestmentValue` snapshots. Drives the
  /// "picker hidden for new trade-driven accounts" branch in
  /// `EditAccountValuationPickerTests`.
  case tradesBrokerage
  /// The Brokerage account from the `.tradeReady` seed (different UUID from
  /// `.brokerage`, which uses the `.tradeBaseline` seed fixture).
  case tradeReadyBrokerage

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .checking: return UITestFixtures.TradeBaseline.checkingAccountId
    case .brokerage: return UITestFixtures.TradeBaseline.brokerageAccountId
    case .tradesBrokerage: return UITestFixtures.TradeBaseline.tradesBrokerageAccountId
    case .tradeReadyBrokerage: return UITestFixtures.TradeReady.brokerageAccountId
    }
  }
}

/// Symbolic reference to a named sidebar leaf (Upcoming, All Transactions,
/// Recently Added, Analysis, Reports, Categories). The `rawValue` is the
/// suffix passed to `UITestIdentifiers.Sidebar.view(_:)`, so it must
/// match the identifier the production view applies in
/// `SidebarView.navigationSection`. `upcoming` deliberately differs from
/// the underlying `SidebarSelection.upcomingTransactions` case — the
/// short identifier mirrors the visible "Upcoming" label.
enum SidebarNamedItem: String {
  case upcoming
  case allTransactions
  case recentlyAdded
  case analysis
  case reports
  case categories
}

/// Driver for the sidebar (left column on macOS): account list, named
/// views (Upcoming, Analysis, etc.), earmarks. Returned from
/// `MoolahApp.sidebar`.
@MainActor
struct SidebarScreen {
  let app: MoolahApp

  /// Switches the centre column to the transactions of the given account.
  /// Returns once the transaction-list container is in the accessibility
  /// tree for the new selection — the user-visible "list re-rendered"
  /// post-condition cited as the example for invariant 1 in
  /// `guides/UI_TEST_GUIDE.md`. `exists` (not `isHittable`) is the
  /// correct predicate: on macOS a SwiftUI `List(selection:)` renders as
  /// an `NSTableView`-backed view whose container element is never
  /// reported as hittable — only its rows are — so polling on
  /// `isHittable` would always time out, even when the list has rendered.
  func switchToAccount(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for account \(account) did not appear within 3s")
      return
    }
    row.click()

    let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
    if !listContainer.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "transaction list container '\(UITestIdentifiers.TransactionList.container)' "
          + "did not appear after switching to \(account)")
      XCTFail(
        "Transaction list did not render within 3s of switching to account \(account)")
    }
  }

  /// Switches the centre column to the named top-level view.
  ///
  /// Returns once the named row's click resolves, then waits on the
  /// leaf's canonical container as a post-condition for the two named
  /// items that expose one: `allTransactions` renders a
  /// `TransactionListView` (via `AllTransactionsView`) and waits on
  /// `UITestIdentifiers.TransactionList.container`; `recentlyAdded`
  /// renders `RecentlyAddedView` and waits on
  /// `UITestIdentifiers.RecentlyAdded.container`. For the remaining
  /// items (`upcoming`, `analysis`, `reports`, `categories`) the leaf is
  /// its own custom surface with no shared identifier, so the next
  /// driver call's `waitForExistence` provides natural quiescence — per
  /// `UI_TEST_GUIDE.md`'s no-sleep rule, no explicit sleep is added.
  func switchToNamed(_ item: SidebarNamedItem) {
    Trace.record(detail: "named=\(item.rawValue)")
    let identifier = UITestIdentifiers.Sidebar.view(item.rawValue)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for named item \(item.rawValue) did not appear within 3s")
      return
    }
    row.click()

    // Post-condition for `allTransactions`, the only named leaf that
    // renders a `TransactionListView`: wait on the canonical list
    // container so the test exits this driver call only after the leaf
    // has rendered.
    switch item {
    case .allTransactions:
      let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
      if !listContainer.waitForExistence(timeout: 3) {
        Trace.recordFailure(
          "transaction list container did not appear after switching to \(item.rawValue)")
        XCTFail("Transaction list did not render within 3s after \(item.rawValue)")
      }
    case .recentlyAdded:
      let recentlyAddedContainer = app.element(
        for: UITestIdentifiers.RecentlyAdded.container)
      if !recentlyAddedContainer.waitForExistence(timeout: 3) {
        Trace.recordFailure(
          "recently added container did not appear after switching to \(item.rawValue)")
        XCTFail("Recently Added did not render within 3s after \(item.rawValue)")
      }
    case .upcoming, .analysis, .reports, .categories:
      // No shared identifier — see docstring.
      break
    }
  }
}

/// Symbolic reference to a sidebar earmark seeded by `TradeBaseline`.
enum SidebarEarmark {
  case renameTarget

  var id: UUID {
    switch self {
    case .renameTarget: return UITestFixtures.TradeBaseline.renameTargetEarmarkId
    }
  }
}

/// Symbolic reference to a sidebar account group seeded by `TradeBaseline`.
enum SidebarGroup {
  case renameTarget

  var id: UUID {
    switch self {
    case .renameTarget: return UITestFixtures.TradeBaseline.renameTargetGroupId
    }
  }
}

extension SidebarScreen {
  // MARK: - Inline rename

  /// Right-clicks the row, clicks the "Rename" item, and waits for the
  /// inline `TextField` to materialise inside the row.
  func beginRenameAccount(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    rightClick(rowIdentifier: UITestIdentifiers.Sidebar.account(account.id))
    clickRenameMenuItem()
    waitForRenameField(rowIdentifier: UITestIdentifiers.Sidebar.account(account.id))
  }

  func beginRenameEarmark(_ earmark: SidebarEarmark) {
    Trace.record(detail: "earmark=\(earmark)")
    rightClick(rowIdentifier: UITestIdentifiers.Sidebar.earmark(earmark.id))
    clickRenameMenuItem()
    waitForRenameField(rowIdentifier: UITestIdentifiers.Sidebar.earmark(earmark.id))
  }

  func beginRenameGroup(_ group: SidebarGroup) {
    Trace.record(detail: "group=\(group)")
    rightClick(rowIdentifier: UITestIdentifiers.Sidebar.group(group.id))
    clickRenameMenuItem()
    waitForRenameField(rowIdentifier: UITestIdentifiers.Sidebar.group(group.id))
  }

  /// Types `text` into the active inline rename field, then presses
  /// Return to commit. The currently-active field (set by
  /// `beginRename*`) keeps keyboard focus; resolving via the most
  /// recently inserted row's `textFields["Name"]` would race the
  /// `beginRename*` wait, so we use the focused-window field instead.
  func typeRenameAndCommit(text: String, inside rowIdentifier: String) {
    Trace.record(detail: "text=\(text) row=\(rowIdentifier)")
    let field = renameField(inside: rowIdentifier)
    field.typeText(text)
    app.pressKeyboardShortcut(XCUIKeyboardKey.return.rawValue)
  }

  /// Presses Esc to cancel the active inline rename.
  func cancelRename() {
    Trace.record()
    app.pressKeyboardShortcut(XCUIKeyboardKey.escape.rawValue)
  }

  /// Selects the account row by clicking it, then presses Return —
  /// the keyboard trigger for inline rename.
  func selectAndPressReturn(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for account \(account) did not appear within 3s")
      return
    }
    row.click()
    app.pressKeyboardShortcut(XCUIKeyboardKey.return.rawValue)
  }

  /// Double-clicks the account row's name to begin rename. Selects
  /// the row first (single click), which is the precondition for the
  /// `.onTapGesture(count: 2)` to attach inside `SidebarRowView`.
  func doubleClickAccountName(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for account \(account) did not appear within 3s")
      return
    }
    row.click()
    row.doubleClick()
  }

  /// Expects the row identified by `rowIdentifier` to be currently
  /// in inline-rename mode. Resolves the inline `TextField` (label
  /// "Name") inside the row's cell descendants.
  func expectRenameFieldVisible(rowIdentifier: String) {
    Trace.record(detail: "row=\(rowIdentifier)")
    let field = renameField(inside: rowIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("rename field did not appear inside '\(rowIdentifier)'")
      XCTFail("Inline rename TextField did not appear within 3s of trigger")
    }
  }

  /// Expects the row to be back in static-label mode (no rename field).
  func expectRenameFieldGone(rowIdentifier: String) {
    Trace.record(detail: "row=\(rowIdentifier)")
    let field = renameField(inside: rowIdentifier)
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
    let result = XCTWaiter.wait(for: [expectation], timeout: 3)
    if result != .completed {
      Trace.recordFailure("rename field still present inside '\(rowIdentifier)'")
      XCTFail("Inline rename TextField did not disappear within 3s of cancel")
    }
  }

  // MARK: - Private helpers

  private func rightClick(rowIdentifier: String) {
    let row = app.element(for: rowIdentifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(rowIdentifier)' did not appear")
      XCTFail("Sidebar row '\(rowIdentifier)' did not appear within 3s")
      return
    }
    row.rightClick()
  }

  private func clickRenameMenuItem() {
    let renameItem = app.element(
      for: UITestIdentifiers.Sidebar.renameContextMenuItem)
    if !renameItem.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "sidebar.contextMenu.rename item did not appear after right-click")
      XCTFail("'Rename' menu item did not appear within 3s of right-click")
      return
    }
    renameItem.click()
  }

  private func waitForRenameField(rowIdentifier: String) {
    let field = renameField(inside: rowIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("rename field did not appear inside '\(rowIdentifier)'")
      XCTFail("Inline rename TextField did not appear within 3s of Rename click")
    }
  }

  private func renameField(inside rowIdentifier: String) -> XCUIElement {
    // The inline TextField inside SidebarRowView is given a stable
    // identifier (`UITestIdentifiers.Sidebar.renameNameField`) so it
    // resolves deterministically through the NSHostingView boundary.
    // We scope the lookup under the row cell so unrelated text fields
    // on other screens don't shadow it during navigation.
    let row = app.element(for: rowIdentifier)
    return row.descendants(matching: .textField)
      .matching(identifier: UITestIdentifiers.Sidebar.renameNameField)
      .firstMatch
  }
}
