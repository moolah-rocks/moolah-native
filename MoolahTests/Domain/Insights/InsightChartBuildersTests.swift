import Foundation
import Testing

@testable import Moolah

@Suite("Insight chart builders")
struct InsightChartBuildersTests {
  private let currency = InsightTestSupport.currency

  @Test
  func insightCarriesAnOptionalChart() {
    let chart = InsightChart(
      kind: .line,
      unit: .percent,
      series: [
        InsightChart.Series(
          id: "rate", label: "Savings rate", role: .primary,
          points: [
            InsightChart.Point(date: InsightTestSupport.date(2026, 1, 1), value: 0.1),
            InsightChart.Point(date: InsightTestSupport.date(2026, 2, 1), value: 0.2),
          ])
      ],
      highlight: InsightChart.Point(date: InsightTestSupport.date(2026, 2, 1), value: 0.2),
      xAxis: .monthly)

    let insight = Insight(
      id: "x", kind: .savingsRateTrend, title: "t", date: InsightTestSupport.now,
      framing: .positive, actionability: .review, surprise: 0.5, chart: chart)

    #expect(insight.chart == chart)
    #expect(insight.chart?.series.first?.points.count == 2)
  }

  @Test
  func insightChartDefaultsToNil() {
    let insight = Insight(
      id: "y", kind: .savingsRateTrend, title: "t", date: InsightTestSupport.now,
      framing: .positive, actionability: .review, surprise: 0.5)
    #expect(insight.chart == nil)
  }

  @Test
  func insightChartCarriesCurrencyUnit() {
    let chart = InsightChart(
      kind: .bar,
      unit: .currency(currency),
      series: [
        InsightChart.Series(
          id: "spend", label: "Spend", role: .primary,
          points: [InsightChart.Point(date: InsightTestSupport.now, value: 12.5)])
      ],
      highlight: nil,
      xAxis: .monthly)
    #expect(chart.unit == .currency(currency))
  }
}
