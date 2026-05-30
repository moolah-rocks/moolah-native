import XCTest

/// XCUITest harness for the main-app side of the Safari web-import seam.
/// XCUITest cannot drive Safari, so this test simulates the
/// extension's contract — a JSON `ImportPayload` written into the
/// shared inbox — via the `.pendingWebImportOneChaseInbox` seed and
/// asserts the rest of the handoff: the banner picks the payload up at
/// first paint, surfaces the expected copy, and tapping Review drains
/// the inbox through `DeepLinkCoordinator` →
/// `ImportStore.startWebReview` (asserted by the inbox file
/// disappearing from disk).
@MainActor
final class ImportExtensionHarnessTests: MoolahUITestCase {
  /// The seed pre-writes a deterministic Chase-shaped `ImportPayload`
  /// into the fallback inbox directory before the app reads it. The
  /// banner therefore renders with the seed's fixed copy on first
  /// paint; tapping Review fires the deep-link drain, which deletes
  /// the inbox file regardless of import outcome (the staging store
  /// owns recovery from there). File disappearance is the deterministic
  /// post-condition.
  func test_pendingInboxBannerSurfacesAndDrainsOnReview() {
    let app = launch(seed: .pendingWebImportOneChaseInbox)

    app.pendingImportsBanner.expectLabel(
      UITestFixtures.PendingWebImportOneChaseInbox.expectedBannerText)
    app.pendingImportsBanner.tapReview()
  }
}
