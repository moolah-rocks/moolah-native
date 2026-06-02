import XCTest

/// UI coverage for the "For You" insights panel (`ForYouCard`) — the first
/// card in the Analysis detail leaf. The `.insightsForYouBaseline` seed
/// boots into the Analysis view with three deterministic fixture insights
/// injected into the `InsightStore`:
///
///   - `largeTxnId`   — references the Checking account → has a "View"
///     deep-link that navigates to that account's detail.
///   - `priceHikeId`  — no navigation target (no "View" button).
///   - `milestoneId`  — no navigation target.
///
/// These tests exercise the rendered SwiftUI panel through the
/// `ForYouScreen` driver: render, dismiss, and deep-link navigation. The
/// store-level dismiss/rank logic is covered by `InsightStore` tests; this
/// suite proves the panel wiring on the real event loop.
@MainActor
final class ForYouPanelUITests: MoolahUITestCase {
  func testForYouPanelRendersSeededInsights() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.largeTxnId)
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.priceHikeId)
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.milestoneId)
  }

  func testDismissRemovesInsight() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    forYou.dismiss(UITestFixtures.InsightsForYou.largeTxnId)

    forYou.expectRowRemoved(UITestFixtures.InsightsForYou.largeTxnId)
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.priceHikeId)
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.milestoneId)
  }

  func testNavigateOpensReferencedAccount() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    forYou.expand(UITestFixtures.InsightsForYou.largeTxnId)
    forYou.tapView(UITestFixtures.InsightsForYou.largeTxnId)

    forYou.expectAccountDetailVisible(named: UITestFixtures.TradeBaseline.checkingAccountName)
  }
}
