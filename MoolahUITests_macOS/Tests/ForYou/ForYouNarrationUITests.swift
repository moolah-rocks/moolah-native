import XCTest

/// UI coverage for the "Why?" narration affordance in the For You card
/// (issue #1042). The `.insightsForYouBaseline` seed injects:
///
///   - Three deterministic fixture insights (same as `ForYouPanelUITests`).
///   - `FixedModelAvailability(.available)` so the "Why?" button renders.
///   - `ScriptedNarrator` that emits `UITestFixtures.InsightsForYou.scriptedNarration`
///     — a known constant — so no real language model is needed on CI hardware.
///
/// The test expands the large-transaction row (which has a "View" button and
/// therefore a reliable expansion post-condition) then taps "Why?" and asserts
/// that the scripted narration string is rendered verbatim.
@MainActor
final class ForYouNarrationUITests: MoolahUITestCase {
  func testWhyButtonRendersScriptedNarration() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()

    // Expand the large-transaction row. The existing `expand` driver method
    // clicks the row header and waits for the "View" button to appear —
    // the reliable expanded-state post-condition for this insight.
    forYou.expand(UITestFixtures.InsightsForYou.largeTxnId)

    // Tap "Why?" and wait for the narration text element to appear.
    forYou.tapWhy(UITestFixtures.InsightsForYou.largeTxnId)

    // Narration streams (`.streaming("")` → partial → `.done`), so predicate-wait
    // on the final content rather than reading the (possibly empty) first frame.
    forYou.expectNarrationText(
      UITestFixtures.InsightsForYou.largeTxnId,
      equals: UITestFixtures.InsightsForYou.scriptedNarration)
  }
}
