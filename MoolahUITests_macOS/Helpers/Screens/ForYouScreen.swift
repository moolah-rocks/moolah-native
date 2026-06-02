import XCTest

/// Driver for the "For You" insights panel (`ForYouCard`), the first card in
/// the Analysis detail leaf. Returned from `MoolahApp.forYou`.
///
/// Each insight renders as a collapsible row keyed by its (stable) insight
/// id: the row header is the expand/collapse control
/// (`UITestIdentifiers.ForYou.row(_:)`), with a sibling dismiss button
/// (`.dismissButton(_:)`). Expanding a row that has a navigation target
/// reveals a "View" deep-link button (`.viewButton(_:)`).
///
/// Every action method records a trace breadcrumb and waits on a real
/// post-condition; expectation methods are read-only and do not record a
/// breadcrumb. All element lookups go through `MoolahApp.element(for:)`,
/// preserving the single-resolver invariant (UI_TEST_GUIDE §3 #5).
@MainActor
struct ForYouScreen {
  let app: MoolahApp

  // MARK: - Presence

  /// Asserts the For You card is on screen. The presence sentinel a
  /// subsequent row / dismiss assertion relies on so it cannot pass
  /// vacuously when the card failed to render.
  func expectCardVisible() {
    let card = app.element(for: UITestIdentifiers.ForYou.card)
    if !card.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou.card did not appear")
      XCTFail("For You card did not render within 5s")
    }
  }

  /// Asserts the insight row for `id` is present.
  func expectRowVisible(_ id: String) {
    let identifier = UITestIdentifiers.ForYou.row(id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou row '\(identifier)' did not appear")
      XCTFail("For You row for '\(id)' did not appear within 5s")
    }
  }

  /// Asserts the insight row for `id` is gone. The post-dismiss signal:
  /// the dismissed insight is removed from the published list and its row
  /// unmounts. Callers must have established a presence sentinel (e.g.
  /// `expectCardVisible()`) so this cannot pass vacuously.
  func expectRowRemoved(_ id: String) {
    let identifier = UITestIdentifiers.ForYou.row(id)
    let row = app.element(for: identifier)
    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure("forYou row '\(identifier)' still present; row not removed")
      XCTFail("For You row for '\(id)' was still present after 5s")
    }
  }

  // MARK: - Actions

  /// Taps the dismiss button for the insight row `id`, then waits for that
  /// row to unmount — the dismissal removes the insight from the published
  /// list, so the row's disappearance is the post-condition.
  func dismiss(_ id: String) {
    Trace.record(#function, detail: "id=\(id)")
    let dismissIdentifier = UITestIdentifiers.ForYou.dismissButton(id)
    let button = app.element(for: dismissIdentifier)
    if !button.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou dismiss button '\(dismissIdentifier)' did not appear")
      XCTFail("For You dismiss button for '\(id)' did not appear within 5s")
      return
    }
    button.click()

    let row = app.element(for: UITestIdentifiers.ForYou.row(id))
    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure(
        "forYou row '\(UITestIdentifiers.ForYou.row(id))' still present 5s after dismiss")
      XCTFail("For You row for '\(id)' did not unmount within 5s of dismiss")
    }
  }

  /// Taps the insight row `id` to expand it, then waits for its "View"
  /// deep-link button to appear — the expanded-state post-condition. Use
  /// only on insights that carry a navigation target (the "View" button is
  /// rendered only then).
  func expand(_ id: String) {
    Trace.record(#function, detail: "id=\(id)")
    let rowIdentifier = UITestIdentifiers.ForYou.row(id)
    let row = app.element(for: rowIdentifier)
    if !row.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou row '\(rowIdentifier)' did not appear")
      XCTFail("For You row for '\(id)' did not appear within 5s")
      return
    }
    row.click()

    let viewIdentifier = UITestIdentifiers.ForYou.viewButton(id)
    let viewButton = app.element(for: viewIdentifier)
    if !viewButton.waitForExistence(timeout: 5) {
      Trace.recordFailure(
        "forYou view button '\(viewIdentifier)' did not appear after expanding")
      XCTFail("For You 'View' button for '\(id)' did not appear within 5s of expanding")
    }
  }

  /// Taps the "View" deep-link button for the (expanded) insight row `id`.
  /// Post-condition assertions are the caller's responsibility — the
  /// navigation outcome is scenario-specific (which leaf the insight
  /// references).
  func tapView(_ id: String) {
    Trace.record(#function, detail: "id=\(id)")
    let viewIdentifier = UITestIdentifiers.ForYou.viewButton(id)
    let viewButton = app.element(for: viewIdentifier)
    if !viewButton.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou view button '\(viewIdentifier)' did not appear")
      XCTFail("For You 'View' button for '\(id)' did not appear within 5s")
      return
    }
    viewButton.click()
  }

  // MARK: - Navigation outcome

  /// Asserts the detail column now shows the account detail for `name`:
  /// the deep-link replaced the Analysis leaf with a `TransactionListView`
  /// filtered to the referenced account. Waits first on the canonical
  /// transaction-list container so a slow re-render doesn't race the scan,
  /// then waits for the account name to surface as the leaf's navigation
  /// title (a static text) — which confirms the *specific* account, not
  /// just any list. The name scan routes through the sanctioned
  /// `MoolahApp.staticTexts(matching:)` escape hatch (UI_TEST_GUIDE §3),
  /// since the navigation title carries no stable accessibility identifier.
  func expectAccountDetailVisible(named name: String) {
    let container = app.element(for: UITestIdentifiers.TransactionList.container)
    if !container.waitForExistence(timeout: 5) {
      Trace.recordFailure(
        "transaction list container '\(UITestIdentifiers.TransactionList.container)' "
          + "did not appear after tapping View")
      XCTFail("Account transaction list did not render within 5s of navigating")
      return
    }
    if !waitForAccountName(name) {
      Trace.recordFailure("account name '\(name)' did not appear in detail within 5s")
      XCTFail("Detail pane did not show account '\(name)' within 5s of navigating")
    }
  }

  // MARK: - Private helpers

  /// Bounded wait for a static text whose label contains `name` to appear
  /// — the navigation title of the account detail leaf. Polls the
  /// `staticTexts` escape-hatch query (no sleeps / no retries: a single
  /// bounded loop that returns as soon as the title lands) up to `timeout`.
  private func waitForAccountName(_ name: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", name)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !app.staticTexts(matching: predicate).isEmpty { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }
}
