import XCTest

/// UI coverage for the inline companion chart on a "For You" insight row.
///
/// The `.insightsForYouBaseline` seed boots into the Analysis view with three
/// deterministic fixture insights. Exactly one — `largeTxnId` — carries an
/// `InsightChart`, so its row renders an inline chart Button
/// (`UITestIdentifiers.ForYou.chart(_:)`). Tapping it presents
/// `InsightChartDetailSheet`, whose expanded chart carries
/// `UITestIdentifiers.ForYou.chartDetail`.
///
/// This suite proves the panel wiring on the real event loop: the inline chart
/// control is present and, when tapped, opens the zoom detail sheet. The
/// chart-building and detector logic is covered by domain/store tests; this is
/// the SwiftUI sheet-presentation seam a store test cannot reach.
@MainActor
final class InsightChartUITests: MoolahUITestCase {
  func testTappingInlineChartOpensDetailSheet() {
    let app = launch(seed: .insightsForYouBaseline)
    let forYou = app.forYou

    forYou.expectCardVisible()
    forYou.expectRowVisible(UITestFixtures.InsightsForYou.largeTxnId)
    // The charted row renders an inline chart Button; the chart-less rows
    // (priceHike, milestone) do not — so this is a real presence sentinel.
    forYou.expectChartVisible(UITestFixtures.InsightsForYou.largeTxnId)

    forYou.tapChart(UITestFixtures.InsightsForYou.largeTxnId)

    forYou.expectChartDetailVisible()
  }
}
