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

  func testShowLessRemovesInsightWithoutBackfill() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    forYou.showLess(UITestFixtures.InsightsForYou.largeTxnId)

    // No backfill: the dismissed row is gone; the others stay put (and no
    // next-ranked insight is promoted into the gap — the seed has exactly
    // three fixtures, all visible).
    forYou.expectRowRemoved(UITestFixtures.InsightsForYou.largeTxnId)
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.priceHikeId)
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.milestoneId)
  }

  func testNavigateOpensReferencedAccount() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    // The "View" deep-link is always visible (no expansion step).
    forYou.tapView(UITestFixtures.InsightsForYou.largeTxnId)

    forYou.expectTransactionListVisible()
  }
}
