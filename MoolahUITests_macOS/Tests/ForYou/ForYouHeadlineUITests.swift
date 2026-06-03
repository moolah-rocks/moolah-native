import XCTest

/// UI coverage for the eager, batch-generated For You headline (issue #1042).
/// The `.insightsForYouBaseline` seed injects:
///
///   - Three deterministic fixture insights (same as `ForYouPanelUITests`).
///   - `FixedModelAvailability(.available)` so headlines are generated.
///   - `ScriptedNarrator` that emits `UITestFixtures.InsightsForYou.scriptedNarration`
///     — a known constant — so no real language model is needed on CI hardware.
///
/// The whole batch is held until every headline resolves, so a visible row
/// already carries its final headline. The test asserts the large-transaction
/// row renders the scripted headline verbatim — inline headline rendering, not
/// a separate narration affordance.
@MainActor
final class ForYouHeadlineUITests: MoolahUITestCase {
  func testRowRendersScriptedHeadline() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.largeTxnId)

    forYou.expectHeadline(
      UITestFixtures.InsightsForYou.largeTxnId,
      equals: UITestFixtures.InsightsForYou.scriptedNarration)
  }
}
