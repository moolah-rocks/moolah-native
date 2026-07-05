import XCTest

/// Smoke test for the `--ui-testing` launch path: launches the app under
/// the `.tradeBaseline` seed and verifies the main window appears.
/// Uses `MoolahUITestCase` so the failure-artefact regime kicks in if
/// the launch ever stops working.
///
/// `MoolahApp.launch(seed:)` itself runs `expectMainWindowVisible()` and
/// fails the test if the window does not appear within 30 s, so the test
/// body only needs to invoke `launch`. No raw `XCUIApplication` calls
/// here — the screen-driver rule (`guides/UI_TEST_GUIDE.md` §2) holds.
@MainActor
final class UITestingLaunchSmokeTests: MoolahUITestCase {
  func testAppLaunchesWithTradeBaselineSeed() {
    _ = launch(seed: .tradeBaseline)
  }
}
