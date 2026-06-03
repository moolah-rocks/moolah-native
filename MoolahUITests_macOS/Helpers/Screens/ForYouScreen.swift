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

  /// Taps the "Why?" narration button for the (expanded) insight row `id`,
  /// then waits for the narration text element to appear — the post-condition
  /// that confirms the narration state transitioned out of `.idle`. The row
  /// must already be expanded (call `expand(id:)` first) and the model must
  /// be available (seed must inject `FixedModelAvailability(.available)`).
  func tapWhy(_ id: String) {
    Trace.record(#function, detail: "id=\(id)")
    let whyIdentifier = UITestIdentifiers.ForYou.whyButton(id)
    let whyButton = app.element(for: whyIdentifier)
    if !whyButton.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou why button '\(whyIdentifier)' did not appear")
      XCTFail("For You 'Why?' button for '\(id)' did not appear within 5s")
      return
    }
    whyButton.click()

    let narrationIdentifier = UITestIdentifiers.ForYou.narrationText(id)
    let narrationElement = app.element(for: narrationIdentifier)
    if !narrationElement.waitForExistence(timeout: 10) {
      Trace.recordFailure(
        "forYou narration text '\(narrationIdentifier)' did not appear after tapping Why?")
      XCTFail("For You narration text for '\(id)' did not appear within 10s of tapping Why?")
    }
  }

  /// Reads the label of the narration text element for insight row `id`.
  /// The element must already exist (call `tapWhy(id:)` first to ensure
  /// the narration state has transitioned). Returns an empty string and
  /// fails the test if the element is not found.
  func narrationText(_ id: String) -> String {
    let narrationIdentifier = UITestIdentifiers.ForYou.narrationText(id)
    let narrationElement = app.element(for: narrationIdentifier)
    if !narrationElement.waitForExistence(timeout: 10) {
      Trace.recordFailure("forYou narration text '\(narrationIdentifier)' did not appear")
      XCTFail("For You narration text for '\(id)' did not appear within 10s")
      return ""
    }
    return narrationElement.label
  }

  // MARK: - Navigation outcome

  /// Confirms navigation landed on a transaction-list detail leaf by waiting
  /// for the transaction-list container — the same signal
  /// `DetailColumnNavigationSweepTests` uses. The Analysis view never renders
  /// this container, so its appearance proves the "View" deep-link navigated
  /// away from the For You panel to the referenced account's detail.
  func expectTransactionListVisible() {
    let container = app.element(for: UITestIdentifiers.TransactionList.container)
    if !container.waitForExistence(timeout: 5) {
      Trace.recordFailure("transaction list did not appear after navigation")
      XCTFail("Transaction list container did not appear after tapping View")
    }
  }
}
