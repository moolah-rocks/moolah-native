import XCTest

/// Base class for every UI test in `MoolahUITests_macOS`. Wires up the
/// failure-artefact regime defined in `guides/UI_TEST_GUIDE.md` §5:
///
///   tree.txt        accessibility-tree dump (one element per line, columns)
///   screenshot.png  full window snapshot
///   seed.txt        seed name + fixture metadata
///   trace.txt       breadcrumb of driver actions, with ✓/✗ outcome marks
///
/// Each artefact is attached to the `XCTestCase` result *and* mirrored to
/// `.agent-tmp/ui-fail-<TestName>/` under the repo root so an agent can
/// debug a failure without spelunking `.xcresult` bundles.
///
/// Tests inherit this class directly:
///
///   @MainActor
///   final class MyTests: MoolahUITestCase { ... }
@MainActor
class MoolahUITestCase: XCTestCase {
  /// The most recently launched `MoolahApp`, captured by `launch(seed:)`
  /// so `tearDown` can collect artefacts and terminate the process.
  private(set) var lastApp: MoolahApp?

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    Trace.reset()
  }

  /// Launches the Moolah app under `--ui-testing` with the given seed and
  /// registers it with this test case so the failure-artefact regime
  /// (`tree.txt`, `screenshot.png`, `seed.txt`, `trace.txt`) fires on
  /// failure.
  ///
  /// Tests use this exclusively rather than constructing a `MoolahApp`
  /// directly:
  ///
  ///   let app = launch(seed: .tradeBaseline)
  func launch(seed: UITestSeed) -> MoolahApp {
    let app = MoolahApp.launch(seed: seed)
    app.testCase = self
    lastApp = app
    return app
  }

  override func tearDown() async throws {
    if let app = lastApp {
      let succeeded = (testRun?.failureCount ?? 0) == 0
      collectFailureArtefacts(for: app, succeeded: succeeded)
      app.application.terminate()
      // Best-effort cleanup of the per-launch inbox directory. Use try?
      // so a missing-or-already-removed directory doesn't mask a real
      // test failure. The directory lives under `/private/tmp` so a
      // miss here is a minor leak, not a correctness problem.
      try? FileManager.default.removeItem(at: app.inboxDirectory)
    }
    lastApp = nil
    try await super.tearDown()
  }

  // MARK: - Driver-internal primitives
  //
  // These are intentionally `internal` so screen drivers in this target can
  // call them. **Tests must not call them directly** — see
  // `guides/UI_TEST_GUIDE.md` §2 (the screen-driver rule). The
  // `ui-test-review` agent flags any test that does.

  /// Bounded wait for an element to appear in the accessibility tree.
  /// Default 10 s. Returns `true` on success; on failure, fails the test
  /// and records the trace before returning `false`.
  @discardableResult
  func waitForIdentifier(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
    guard let app = lastApp else {
      XCTFail("waitForIdentifier called before MoolahApp.launch(seed:)")
      return false
    }
    if app.waitForElement(identifier: identifier, timeout: timeout) { return true }
    Trace.recordFailure("waitForIdentifier '\(identifier)' timed out")
    XCTFail("Identifier '\(identifier)' did not appear within \(timeout)s")
    return false
  }

  /// Asserts that the element with the given identifier currently has
  /// keyboard focus. Drivers use this to back `expectFocused()`.
  func assertFocused(_ identifier: String) {
    guard let app = lastApp else {
      XCTFail("assertFocused called before MoolahApp.launch(seed:)")
      return
    }
    let element = app.element(for: identifier)
    if !element.exists {
      Trace.recordFailure("assertFocused: identifier '\(identifier)' not found")
      XCTFail("assertFocused: element '\(identifier)' not in accessibility tree")
      return
    }
    let hasFocus = (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    if !hasFocus {
      Trace.recordFailure("assertFocused: '\(identifier)' is not focused")
      XCTFail("Element '\(identifier)' did not have keyboard focus")
    }
  }

  /// Types text into the element with the given identifier. Drivers wrap
  /// this with their own action method (e.g. `AutocompleteFieldDriver.type`).
  func typeInto(_ identifier: String, text: String) {
    guard let app = lastApp else {
      XCTFail("typeInto called before MoolahApp.launch(seed:)")
      return
    }
    let element = app.element(for: identifier)
    if !element.waitForExistence(timeout: 10) {
      Trace.recordFailure("typeInto: '\(identifier)' not found")
      XCTFail("typeInto: element '\(identifier)' did not appear within 10s")
      return
    }
    element.click()
    element.typeText(text)
  }

  /// Sends a keyboard key press to the focused element with optional
  /// modifiers. Drivers use this to back `pressArrowDown()`, `pressEnter()`,
  /// etc.
  func pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
    guard let app = lastApp else {
      XCTFail("pressKey called before MoolahApp.launch(seed:)")
      return
    }
    app.application.typeKey(key, modifierFlags: modifiers)
  }

}
