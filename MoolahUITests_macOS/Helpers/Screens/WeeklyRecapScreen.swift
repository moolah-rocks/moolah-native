import XCTest

/// Driver for the weekly recap card (`WeeklyRecapCard`) rendered above the
/// "For You" panel on the Analysis surface. Returned from `MoolahApp.weeklyRecap`.
///
/// The card appears when `WeeklyRecapStore.recap` transitions to `.ready`
/// (scripted deterministically in the `.weeklyRecapBaseline` seed). Its
/// header carries `UITestIdentifiers.WeeklyRecap.card`; the prose text
/// carries `UITestIdentifiers.WeeklyRecap.recapText`; the dismiss button
/// carries `UITestIdentifiers.WeeklyRecap.dismiss`.
///
/// Every action method records a trace breadcrumb and waits on a real
/// post-condition; expectation methods are read-only. All element lookups
/// go through `MoolahApp.element(for:)`, preserving the single-resolver
/// invariant (UI_TEST_GUIDE §3 #5).
@MainActor
struct WeeklyRecapScreen {
  let app: MoolahApp

  // MARK: - Presence

  /// Waits for the recap card to appear and fails the test if it does not.
  /// The card identifier is on the "Your week in review" header text — a
  /// stable, always-rendered element when the store is in `.ready` state.
  func waitForCard() {
    let card = app.element(for: UITestIdentifiers.WeeklyRecap.card)
    if !card.waitForExistence(timeout: 10) {
      Trace.recordFailure("weeklyRecap.card did not appear within 10s")
      XCTFail("Weekly recap card did not appear within 10s")
    }
  }

  /// Asserts that the recap card is gone from the accessibility tree. Requires
  /// that `waitForCard()` has already established a presence sentinel so this
  /// cannot pass vacuously on an app that never rendered the card.
  func expectCardGone() {
    let card = app.element(for: UITestIdentifiers.WeeklyRecap.card)
    if !card.waitForNonExistence(timeout: 5) {
      Trace.recordFailure("weeklyRecap.card still present after dismiss")
      XCTFail("Weekly recap card was still present 5s after dismiss")
    }
  }

  // MARK: - Content

  /// Reads the recap prose `Text` element. SwiftUI exposes the prose through
  /// the element's `value` (it surfaces as a text view), not its `label`, so
  /// this prefers `value` and falls back to `label`. Fails the test and returns
  /// an empty string when the element is not found — the caller's assertion
  /// will then report the mismatch clearly.
  func recapText() -> String {
    let textElement = app.element(for: UITestIdentifiers.WeeklyRecap.recapText)
    if !textElement.waitForExistence(timeout: 10) {
      Trace.recordFailure("weeklyRecap.recapText did not appear within 10s")
      XCTFail("Weekly recap text element did not appear within 10s")
      return ""
    }
    let value = (textElement.value as? String) ?? ""
    return value.isEmpty ? textElement.label : value
  }

  /// Waits for the recap prose element to render `expected` verbatim, matching
  /// either `value` (where SwiftUI surfaces the prose) or `label`. Predicate-
  /// waiting avoids reading the element a beat before its content is published.
  func expectRecapText(equals expected: String) {
    Trace.record(#function)
    let textElement = app.element(for: UITestIdentifiers.WeeklyRecap.recapText)
    let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: textElement)
    if XCTWaiter().wait(for: [expectation], timeout: 10) != .completed {
      let seen = (textElement.value as? String) ?? textElement.label
      Trace.recordFailure("weeklyRecap.recapText never matched expected; last='\(seen)'")
      XCTFail(
        "Weekly recap text did not render the scripted output within 10s (last seen: '\(seen)')")
    }
  }

  // MARK: - Actions

  /// Taps the dismiss button, then waits for the recap card to unmount — the
  /// card's disappearance is the deterministic post-condition that the store
  /// transitioned to `.hidden`.
  func dismiss() {
    Trace.record(#function)
    let dismissButton = app.element(for: UITestIdentifiers.WeeklyRecap.dismiss)
    if !dismissButton.waitForExistence(timeout: 5) {
      Trace.recordFailure("weeklyRecap.dismiss button did not appear")
      XCTFail("Weekly recap dismiss button did not appear within 5s")
      return
    }
    dismissButton.click()
    expectCardGone()
  }
}
