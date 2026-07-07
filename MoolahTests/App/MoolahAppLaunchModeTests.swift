import Testing

@testable import Moolah

@Suite("MoolahApp launch mode")
struct MoolahAppLaunchModeTests {
  @Test("unit tests suppress automatic main-window presentation")
  func unitTestsSuppressAutomaticMainWindowPresentation() {
    #expect(
      MoolahApp.shouldSuppressAutomaticMainWindow(isUITesting: false, isRunningTests: true))
  }

  @Test("UI tests keep automatic window policy available for launcher-driven presentation")
  func uiTestsKeepAutomaticWindowPolicyAvailableForLauncherDrivenPresentation() {
    #expect(
      !MoolahApp.shouldSuppressAutomaticMainWindow(isUITesting: true, isRunningTests: true))
  }

  @Test("production launches keep automatic main-window presentation")
  func productionLaunchesKeepAutomaticMainWindowPresentation() {
    #expect(
      !MoolahApp.shouldSuppressAutomaticMainWindow(isUITesting: false, isRunningTests: false))
  }
}
