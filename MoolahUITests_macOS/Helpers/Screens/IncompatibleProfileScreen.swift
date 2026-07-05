import XCTest

/// Driver for `IncompatibleProfileView`. Returned from
/// `MoolahApp.incompatibleProfile`. See `guides/UI_TEST_GUIDE.md` §3
/// for the invariants this driver upholds (single resolver, no
/// caching, `Trace.record(#function)` first, post-condition waits,
/// explicit `XCTFail` on failure).
@MainActor
struct IncompatibleProfileScreen {
  let app: MoolahApp

  // MARK: - Expectations

  func expectVisible(timeout: TimeInterval = 10) {
    Trace.record()
    let root = app.element(for: UITestIdentifiers.IncompatibleProfile.root)
    if !root.waitForExistence(timeout: timeout) {
      Trace.recordFailure("IncompatibleProfileView did not appear")
      XCTFail("IncompatibleProfileView did not appear within \(timeout)s")
    }
  }

  func expectCheckForUpdatesVisible(timeout: TimeInterval = 10) {
    Trace.record()
    let button = app.element(for: UITestIdentifiers.IncompatibleProfile.checkForUpdates)
    if !button.waitForExistence(timeout: timeout) {
      Trace.recordFailure("checkForUpdates button did not appear")
      XCTFail("Check for Updates button did not appear within \(timeout)s")
    }
  }

  func expectSwitchProfileVisible(timeout: TimeInterval = 10) {
    Trace.record()
    let button = app.element(for: UITestIdentifiers.IncompatibleProfile.switchProfile)
    if !button.waitForExistence(timeout: timeout) {
      Trace.recordFailure("switchProfile button did not appear")
      XCTFail("Switch Profile button did not appear within \(timeout)s")
    }
  }

  // MARK: - Actions

  func tapCheckForUpdates() {
    Trace.record()
    let button = app.element(for: UITestIdentifiers.IncompatibleProfile.checkForUpdates)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("checkForUpdates button did not appear")
      XCTFail("Check for Updates button did not appear within 10s")
      return
    }
    button.click()
    let root = app.element(for: UITestIdentifiers.IncompatibleProfile.root)
    if !root.waitForExistence(timeout: 10) {
      Trace.recordFailure("IncompatibleProfileView dismissed unexpectedly after tapCheckForUpdates")
      XCTFail("IncompatibleProfileView was dismissed after tapping Check for Updates")
    }
  }

  func tapSwitchProfile(timeout: TimeInterval = 10) {
    Trace.record()
    let button = app.element(for: UITestIdentifiers.IncompatibleProfile.switchProfile)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("switchProfile button did not appear")
      XCTFail("Switch Profile button did not appear within 10s")
      return
    }
    button.click()
    let root = app.element(for: UITestIdentifiers.IncompatibleProfile.root)
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: root)
    if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
      Trace.recordFailure("IncompatibleProfileView did not dismiss after tapSwitchProfile")
      XCTFail("IncompatibleProfileView was still on screen after tapping Switch Profile")
    }
  }
}
