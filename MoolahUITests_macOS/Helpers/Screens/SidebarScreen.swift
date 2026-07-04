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
  /// The Ethereum wallet from the `.walletHeaderSyncError` seed. Used by
  /// `SyncedAccountHeaderTests` to navigate to the crypto account detail.
  case walletWithSyncError

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .checking: return UITestFixtures.TradeBaseline.checkingAccountId
    case .brokerage: return UITestFixtures.TradeBaseline.brokerageAccountId
    case .tradesBrokerage: return UITestFixtures.TradeBaseline.tradesBrokerageAccountId
    case .tradeReadyBrokerage: return UITestFixtures.TradeReady.brokerageAccountId
    case .walletWithSyncError: return UITestFixtures.WalletHeaderSyncError.walletAccountId
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

/// Symbolic reference to a sidebar account group.
enum SidebarGroup {
  /// `.tradeBaseline`'s empty rename-target group.
  case renameTarget
  /// `.groupFilterScope`'s two-member "Filter Group".
  case filterGroup

  var id: UUID {
    switch self {
    case .renameTarget: return UITestFixtures.TradeBaseline.renameTargetGroupId
    case .filterGroup: return UITestFixtures.GroupFilterScope.filterGroupId
    }
  }
}

extension SidebarScreen {
  // MARK: - Inline rename

  /// Right-clicks the row, clicks the "Rename" item, and waits for the
  /// inline `TextField` to materialise.
  func beginRenameAccount(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    rightClick(rowIdentifier: UITestIdentifiers.Sidebar.account(account.id))
    clickRenameMenuItem()
    waitForRenameField()
  }

  func beginRenameEarmark(_ earmark: SidebarEarmark) {
    Trace.record(detail: "earmark=\(earmark)")
    rightClick(rowIdentifier: UITestIdentifiers.Sidebar.earmark(earmark.id))
    clickRenameMenuItem()
    waitForRenameField()
  }

  func beginRenameGroup(_ group: SidebarGroup) {
    Trace.record(detail: "group=\(group)")
    rightClick(rowIdentifier: UITestIdentifiers.Sidebar.group(group.id))
    clickRenameMenuItem()
    waitForRenameField()
  }

  /// Types `text` into the active inline rename field, then presses
  /// Return to commit. Waits for the field to unmount as the
  /// post-condition: SwiftUI removes the `TextField` once the store
  /// processes the commit.
  func typeRenameAndCommit(_ text: String) {
    Trace.record(detail: "text=\(text)")
    let field = renameField()
    field.typeText(text)
    app.pressKeyboardShortcut(XCUIKeyboardKey.return.rawValue)
    waitForRenameFieldGone()
  }

  /// Presses Esc to cancel the active inline rename. Waits for the
  /// field to unmount as the post-condition.
  func cancelRename() {
    Trace.record()
    app.pressKeyboardShortcut(XCUIKeyboardKey.escape.rawValue)
    waitForRenameFieldGone()
  }

  /// Selects the account row by clicking it, then presses Return —
  /// the keyboard trigger for inline rename. Waits for the field to
  /// appear as the post-condition.
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
    waitForRenameField()
  }

  /// Double-clicks the account row's name to begin rename. Selects
  /// the row first (single click) so the `.onTapGesture(count: 2)`
  /// attaches inside `SidebarRowView.nameLabel`. Waits for the field
  /// as the post-condition.
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
    waitForRenameField()
  }

  /// Synchronous assertion that the rename field is currently visible.
  /// Action methods carry the wait; this is for tests verifying that a
  /// trigger landed the UI in edit mode.
  func expectRenameFieldVisible() {
    Trace.record()
    if !renameField().exists {
      Trace.recordFailure("rename field not visible")
      XCTFail("Inline rename TextField is not present")
    }
  }

  /// Synchronous assertion that the rename field is not currently
  /// visible. Action methods carry the wait; this is for tests
  /// verifying that the UI has returned to static-label mode.
  func expectRenameFieldGone() {
    Trace.record()
    if renameField().exists {
      Trace.recordFailure("rename field still visible")
      XCTFail("Inline rename TextField is still present")
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

  /// Resolves the inline rename `TextField` via the stable
  /// `renameNameField` identifier. Only ever applied to the single
  /// inline `TextField` in `InlineRenameField`, so a global lookup
  /// through `MoolahApp.element(for:)` is unambiguous.
  private func renameField() -> XCUIElement {
    app.element(for: UITestIdentifiers.Sidebar.renameNameField)
  }

  /// Waits for the inline rename field to materialise. Used as the
  /// post-condition for `beginRename*`, `selectAndPressReturn`, and
  /// `doubleClickAccountName`.
  private func waitForRenameField() {
    let field = renameField()
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("rename field did not appear")
      XCTFail("Inline rename TextField did not appear within 3s of trigger")
    }
  }

  /// Waits for the inline rename field to disappear. Used as the
  /// post-condition for `typeRenameAndCommit` and `cancelRename`.
  private func waitForRenameFieldGone() {
    let field = renameField()
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
    let result = XCTWaiter.wait(for: [expectation], timeout: 3)
    if result != .completed {
      Trace.recordFailure("rename field still present")
      XCTFail("Inline rename TextField did not disappear within 3s")
    }
  }
}

extension SidebarScreen {
  // MARK: - Drag-and-drop (issue #991)

  /// Drags the source account's row onto the target account's row using
  /// `press(forDuration:thenDragTo:)`. XCUITest's primitive always lands
  /// the drop on the centre of the target row, which the
  /// `SidebarDropPolicy` interprets as "drop onto" rather than "reorder
  /// between rows" — callers expecting a group-create outcome are aligned
  /// with the API's affordance.
  ///
  /// Waits on both rows existing before initiating the press so a slow
  /// first paint doesn't race the gesture. Post-condition assertions are
  /// the caller's responsibility — drag outcomes are scenario-specific
  /// (group created / rename field visible / membership changed).
  func dragAccount(_ source: SidebarAccount, ontoAccount target: SidebarAccount) {
    Trace.record(detail: "source=\(source) target=\(target)")
    let sourceIdentifier = UITestIdentifiers.Sidebar.account(source.id)
    let targetIdentifier = UITestIdentifiers.Sidebar.account(target.id)
    let sourceRow = app.element(for: sourceIdentifier)
    let targetRow = app.element(for: targetIdentifier)
    if !sourceRow.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(sourceIdentifier)' did not appear")
      XCTFail("Sidebar row for source account \(source) did not appear within 3s")
      return
    }
    if !targetRow.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(targetIdentifier)' did not appear")
      XCTFail("Sidebar row for target account \(target) did not appear within 3s")
      return
    }
    sourceRow.press(forDuration: 0.4, thenDragTo: targetRow)
  }

  /// Drags the source account's row onto the target group's row. Same
  /// centre-of-row landing semantics as `dragAccount(_:ontoAccount:)`;
  /// the policy maps a centre-of-row drop on a group to "add to group".
  func dragAccount(_ source: SidebarAccount, ontoGroup target: SidebarGroup) {
    Trace.record(detail: "source=\(source) group=\(target)")
    let sourceIdentifier = UITestIdentifiers.Sidebar.account(source.id)
    let targetIdentifier = UITestIdentifiers.Sidebar.group(target.id)
    let sourceRow = app.element(for: sourceIdentifier)
    let targetRow = app.element(for: targetIdentifier)
    if !sourceRow.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(sourceIdentifier)' did not appear")
      XCTFail("Sidebar row for source account \(source) did not appear within 3s")
      return
    }
    if !targetRow.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(targetIdentifier)' did not appear")
      XCTFail("Sidebar row for target group \(target) did not appear within 3s")
      return
    }
    sourceRow.press(forDuration: 0.4, thenDragTo: targetRow)
  }
}
