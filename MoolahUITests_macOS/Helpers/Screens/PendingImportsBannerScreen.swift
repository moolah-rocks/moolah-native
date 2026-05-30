import XCTest

/// Driver for the in-window `PendingImportsBanner` that surfaces
/// unconsumed inbox payloads written by the Safari import extension.
/// Returned from `MoolahApp.pendingImportsBanner`.
///
/// The banner is conditionally rendered — its label and Review button
/// are in the accessibility tree only when the inbox is non-empty (the
/// view body returns `EmptyView` otherwise) — so the driver waits on
/// the label as the non-empty sentinel before asserting copy text or
/// clicking Review. All identifier lookups go through
/// `MoolahApp.element(for:)`; action methods record a trace breadcrumb
/// and wait on a real post-condition (UI_TEST_GUIDE §3 invariants).
@MainActor
struct PendingImportsBannerScreen {
  let app: MoolahApp

  // MARK: - Expectations

  /// Returns the accessible text of an element: the accessibility label
  /// when non-empty, otherwise the value string. SwiftUI `Text` views
  /// with `.accessibilityIdentifier(_:)` set expose their content
  /// through `.value` rather than `.label` in XCUITest. Mirrors
  /// `SyncFooterScreen.text(of:)`.
  private func text(of element: XCUIElement) -> String {
    let labelText = element.label
    if !labelText.isEmpty { return labelText }
    return element.value as? String ?? ""
  }

  /// Waits for the banner label to appear and returns it. Fails the
  /// test (and records the failure in the trace) if it does not exist
  /// within `timeout` seconds. The label is the visible-banner sentinel:
  /// when the inbox is empty the body resolves to `EmptyView` and no
  /// label element is in the tree.
  @discardableResult
  func expectVisible(timeout: TimeInterval = 5) -> XCUIElement {
    let label = app.element(for: UITestIdentifiers.PendingImportsBanner.label)
    if !label.waitForExistence(timeout: timeout) {
      Trace.recordFailure("pending-imports banner did not appear")
      XCTFail("Pending imports banner did not appear within \(timeout)s")
    }
    return label
  }

  /// Asserts that the banner copy equals `expected`. Waits for the
  /// banner to appear first so this cannot pass vacuously on an empty
  /// inbox (the view returns `EmptyView` and the label element is then
  /// absent from the tree).
  func expectLabel(_ expected: String, timeout: TimeInterval = 5) {
    Trace.record(#function, detail: "label=\(expected)")
    let label = expectVisible(timeout: timeout)
    let actual = text(of: label)
    if actual != expected {
      Trace.recordFailure("label '\(actual)' != '\(expected)'")
      XCTFail("Expected pending-imports banner label '\(expected)'; got '\(actual)'")
    }
  }

  // MARK: - Actions

  /// Clicks the banner's `Review` button. Post-condition: the click
  /// dispatches `PendingImportsBannerModel.reviewTapped()` →
  /// `DeepLinkCoordinator.handle(.importInbox(id:))`, which is async; we
  /// wait for the inbox file to be drained (the coordinator deletes it
  /// after `ImportStore.startWebReview` returns) by polling
  /// `FileManager` against the fixture's known on-disk path
  /// (`app.inboxDirectory`, mirrored from the launch-time env var).
  func tapReview() {
    Trace.record(#function)
    let button = app.element(for: UITestIdentifiers.PendingImportsBanner.reviewButton)
    if !button.waitForExistence(timeout: 5) {
      Trace.recordFailure("pending-imports banner review button did not appear")
      XCTFail("Review button did not appear within 5s")
      return
    }
    button.click()
    if !waitForInboxDrain() {
      Trace.recordFailure("inbox payload was not drained 5s after Review tap")
      XCTFail("Review tap did not drain the inbox payload within 5s")
    }
  }

  // MARK: - Private helpers

  /// Bounded wait for the seeded inbox file to disappear from disk —
  /// the deterministic post-condition of a Review tap.
  /// `DeepLinkCoordinator.drainInbox` reads the payload, hands it to
  /// `ImportStore.startWebReview`, then deletes the file regardless of
  /// import outcome (the staging store owns recovery from there), so
  /// file disappearance is the cleanest signal that the seam fired.
  private func waitForInboxDrain() -> Bool {
    let payloadId = UITestFixtures.PendingWebImportOneChaseInbox.payloadId
    let url =
      app.inboxDirectory
      .appendingPathComponent("Inbox")
      .appendingPathComponent("\(payloadId.uuidString).json")
    let predicate = NSPredicate { _, _ in
      !FileManager.default.fileExists(atPath: url.path)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
  }
}
