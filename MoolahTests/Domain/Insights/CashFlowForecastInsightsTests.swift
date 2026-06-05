import Foundation
import Testing

@testable import Moolah

/// Tests for `CashFlowForecastInsights.projectedMonthEnd` — month-end balance
/// projection that suppresses noise (wide confidence bands) and reports a
/// rounded, ballpark figure rather than a to-the-cent value.
@Suite("Cash-flow month-end forecast")
struct CashFlowForecastInsightsTests {
  private let context = InsightTestSupport.context()

  /// A historical (non-forecast) balance on `daysAgo`.
  private func actual(_ quantity: Decimal, daysAgo days: Int) -> DailyBalance {
    DailyBalance(
      date: InsightTestSupport.daysAgo(days), balance: InsightTestSupport.amount(quantity))
  }

  /// A forecast balance dated `day` of the current financial month (June 2026).
  private func forecast(_ quantity: Decimal, day: Int) -> DailyBalance {
    actual(quantity, daysAgo: 0)
      .withDate(InsightTestSupport.date(2026, 6, day), isForecast: true)
  }

  @Test
  func suppressesForecastWhenBandIsAtLeastHalfOfProjected() {
    // Large alternating day-over-day deltas → a band of roughly 8000 × √14 ≈
    // 29,900, dwarfing the ~10,000 projection (band ≥ 0.5 × |projected|).
    let history = [
      actual(1_000, daysAgo: 4),
      actual(9_000, daysAgo: 3),
      actual(1_000, daysAgo: 2),
      actual(9_000, daysAgo: 1),
    ]
    let projection = [forecast(10_000, day: 20)]
    let insights = CashFlowForecastInsights.projectedMonthEnd(
      dailyBalances: history + projection, context: context)
    #expect(insights.isEmpty)
  }

  @Test
  func showsRoundedProjectionWhenBandIsNarrow() throws {
    // Near-constant history → band ≈ 0, well under half the projection.
    let history = [
      actual(224_998, daysAgo: 3),
      actual(224_999, daysAgo: 2),
      actual(225_000, daysAgo: 1),
    ]
    let projection = [forecast(225_460, day: 20)]
    let insights = CashFlowForecastInsights.projectedMonthEnd(
      dailyBalances: history + projection, context: context)

    #expect(insights.count == 1)
    let insight = try #require(insights.first)
    // Rounded ballpark figure, not the to-the-cent projection. The test
    // currency renders as "USD 225,000"; assert the rounded magnitude and
    // the absence of the precise figure and its cents.
    #expect(insight.title.contains("225,000"))
    #expect(!insight.title.contains("225,460"))
    #expect(!insight.title.contains(".00"))
    #expect(!insight.facts.contains { $0.label == "Confidence band" })
    // No impact badge: the rounded projection lives in the headline, so an
    // exact to-the-cent impact amount would contradict it.
    #expect(insight.monetaryImpact == nil)
    #expect(insight.chart != nil)
    #expect(insight.chart?.series.contains { $0.role == .projected } == true)
  }
}
