import XCTest

/// Driver for the sidebar sync-progress footer (`SyncProgressFooter`).
///
/// Returned from `MoolahApp.syncFooter`.
@MainActor
struct SyncFooterScreen {
  let app: MoolahApp

  // MARK: - Expectations

  /// Returns the accessible text of an element: the accessibility label when
  /// non-empty, otherwise the value string. SwiftUI `Text` views with
  /// `.accessibilityIdentifier` set expose their content through `.value`
  /// rather than `.label` in XCUITest.
  private func text(of element: XCUIElement) -> String {
    let labelText = element.label
    if !labelText.isEmpty { return labelText }
    return element.value as? String ?? ""
  }

  /// Asserts that the footer's primary label equals `expectedLabel`.
  /// Waits up to `timeout` seconds for the footer to appear.
  func expectLabel(_ expectedLabel: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "label=\(expectedLabel)")
    let element = app.element(for: UITestIdentifiers.SyncFooter.label)
    if !element.waitForExistence(timeout: timeout) {
      Trace.recordFailure("sync footer label did not appear")
      XCTFail("Sync footer label did not appear within \(timeout)s")
      return
    }
    let actual = text(of: element)
    if actual != expectedLabel {
      Trace.recordFailure("label '\(actual)' != '\(expectedLabel)'")
      XCTFail("Expected sync footer label '\(expectedLabel)'; got '\(actual)'")
    }
  }

  /// Asserts that the footer's detail line equals `expectedDetail`.
  func expectDetail(_ expectedDetail: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "detail=\(expectedDetail)")
    let element = app.element(for: UITestIdentifiers.SyncFooter.detail)
    if !element.waitForExistence(timeout: timeout) {
      Trace.recordFailure("sync footer detail did not appear")
      XCTFail("Sync footer detail did not appear within \(timeout)s")
      return
    }
    let actual = text(of: element)
    if actual != expectedDetail {
      Trace.recordFailure("detail '\(actual)' != '\(expectedDetail)'")
      XCTFail("Expected sync footer detail '\(expectedDetail)'; got '\(actual)'")
    }
  }

  /// Asserts that the footer's detail line contains both `prefix` and
  /// `suffix` fragments. Used for relative-timestamp assertions where the
  /// exact string depends on wall-clock time.
  func expectDetailContains(prefix: String, suffix: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "prefix=\(prefix) suffix=\(suffix)")
    let element = app.element(for: UITestIdentifiers.SyncFooter.detail)
    if !element.waitForExistence(timeout: timeout) {
      Trace.recordFailure("sync footer detail did not appear")
      XCTFail("Sync footer detail did not appear within \(timeout)s")
      return
    }
    let actual = text(of: element)
    let ok = actual.contains(prefix) && actual.contains(suffix)
    if !ok {
      Trace.recordFailure(
        "detail '\(actual)' did not contain prefix '\(prefix)' and suffix '\(suffix)'"
      )
      XCTFail(
        "Expected sync footer detail to contain '\(prefix)' and '\(suffix)'; got '\(actual)'"
      )
    }
  }
}
