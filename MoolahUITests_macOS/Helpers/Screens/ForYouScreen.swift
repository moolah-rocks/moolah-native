import XCTest

/// Driver for the "For You" insights panel (`ForYouCard`), the first card in
/// the Analysis detail leaf. Returned from `MoolahApp.forYou`.
///
/// Each insight renders as a single headline row keyed by its (stable) insight
/// id (`UITestIdentifiers.ForYou.row(_:)`): a headline line
/// (`.headline(_:)`), a "Show less" control (`.showLess(_:)`), and — when the
/// insight has a navigation target — an always-visible "View" deep-link button
/// (`.viewButton(_:)`).
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

  /// Taps the "Show less" control for the insight row `id`, then waits for that
  /// row to unmount — "Show less" removes the insight from the published batch,
  /// so the row's disappearance is the post-condition.
  func showLess(_ id: String) {
    Trace.record(#function, detail: "id=\(id)")
    let showLessIdentifier = UITestIdentifiers.ForYou.showLess(id)
    let button = app.element(for: showLessIdentifier)
    if !button.waitForExistence(timeout: 5) {
      Trace.recordFailure("forYou show-less control '\(showLessIdentifier)' did not appear")
      XCTFail("For You 'Show less' control for '\(id)' did not appear within 5s")
      return
    }
    button.click()

    let row = app.element(for: UITestIdentifiers.ForYou.row(id))
    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure(
        "forYou row '\(UITestIdentifiers.ForYou.row(id))' still present 5s after show-less")
      XCTFail("For You row for '\(id)' did not unmount within 5s of 'Show less'")
    }
  }

  /// Taps the "View" deep-link button for the insight row `id`. The button is
  /// always visible (no expansion needed). Post-condition assertions are the
  /// caller's responsibility — the navigation outcome is scenario-specific
  /// (which leaf the insight references).
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

    // Tapping "View" changes the sidebar selection, swapping the detail pane
    // away from the Analysis/For You card — so the For You row unmounts. Wait
    // on that disappearance as the post-condition (actions must not return
    // before a known signal). Scenario-specific landing assertions
    // (e.g. `expectTransactionListVisible()`) remain the caller's job.
    let row = app.element(for: UITestIdentifiers.ForYou.row(id))
    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure(
        "forYou row '\(UITestIdentifiers.ForYou.row(id))' still present 5s after tapView "
          + "— navigation may not have fired")
      XCTFail("For You row for '\(id)' did not leave the screen within 5s of tapping View")
    }
  }

  // MARK: - Headline

  /// Waits for the headline element for `id` to render `expected` verbatim.
  /// Headlines are generated eagerly and the whole batch is held until ready,
  /// so the row only mounts once its final headline is resolved; this
  /// predicate-waits on the content as the robust post-condition.
  ///
  /// The headline raw text is exposed in `.value` because the `Text` carries no
  /// `.accessibilityLabel`/`.accessibilityValue` override (SwiftUI surfaces
  /// prose `Text` through `value`, not `label`), so the predicate matches
  /// `.value`.
  func expectHeadline(_ id: String, equals expected: String) {
    let headlineIdentifier = UITestIdentifiers.ForYou.headline(id)
    let headlineElement = app.element(for: headlineIdentifier)
    let predicate = NSPredicate(format: "value == %@", expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: headlineElement)
    if XCTWaiter().wait(for: [expectation], timeout: 10) != .completed {
      let seen = (headlineElement.value as? String) ?? headlineElement.label
      Trace.recordFailure(
        "forYou headline '\(id)' never rendered the expected output; last='\(seen)'")
      XCTFail(
        "For You headline for '\(id)' did not render the expected output within 10s "
          + "(last seen: '\(seen)')")
    }
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
