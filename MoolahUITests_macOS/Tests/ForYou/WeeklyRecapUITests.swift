import XCTest

/// UI coverage for the weekly recap card (`WeeklyRecapCard`) rendered above
/// the "For You" panel on the Analysis surface (issue #1042). The
/// `.weeklyRecapBaseline` seed injects:
///
///   - Three deterministic fixture insights (same set as
///     `ForYouPanelUITests` — the recap reads `insightStore.insights`).
///   - `FixedModelAvailability(.available)` so the model-availability gate
///     passes.
///   - `ScriptedNarrator` emitting
///     `UITestFixtures.InsightsForYou.scriptedRecap` — a known constant —
///     so no real language model is needed on CI hardware.
///   - Opt-in forced on (`isOptedIn` closure returns `true`).
///   - A fresh `InMemoryRecapLastShownStore` (never shown), ensuring
///     `WeeklyRecapWindow.shouldShow` returns `true` immediately.
///
/// The test launches into the seed, waits for the recap card, asserts the
/// scripted recap string, then dismisses the card and confirms it is gone.
@MainActor
final class WeeklyRecapUITests: MoolahUITestCase {
  func testRecapCardRendersScriptedTextAndDismissHidesIt() {
    let app = launch(seed: .weeklyRecapBaseline)
    let recap = app.weeklyRecap

    // Wait for the recap card to appear and assert the scripted text.
    recap.waitForCard()
    let rendered = recap.recapText()
    XCTAssertEqual(
      rendered,
      UITestFixtures.InsightsForYou.scriptedRecap,
      "Recap text did not match the scripted narrator's output"
    )

    // Dismiss the card and confirm it is gone.
    recap.dismiss()
  }
}
