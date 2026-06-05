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

  @Test
  func categorySpendChartHighlightsTheGivenMonth() throws {
    let points = [
      MonthlySpendPoint(month: "202604", date: InsightTestSupport.date(2026, 4, 1), magnitude: 100),
      MonthlySpendPoint(month: "202605", date: InsightTestSupport.date(2026, 5, 1), magnitude: 110),
      MonthlySpendPoint(month: "202606", date: InsightTestSupport.date(2026, 6, 1), magnitude: 400),
    ]
    let chart = try #require(
      InsightChartBuilders.categorySpend(
        points: points, reportingCurrency: currency, highlightMonth: "202606"))

    #expect(chart.kind == .bar)
    #expect(chart.unit == .currency(currency))
    #expect(chart.xAxis == .monthly)
    #expect(chart.series.count == 1)
    #expect(chart.series.first?.id == "spend")
    #expect(chart.series.first?.role == .primary)
    #expect(chart.series.first?.points.count == 3)
    #expect(chart.highlight?.value == 400)
    #expect(chart.highlight?.date == InsightTestSupport.date(2026, 6, 1))
  }

  @Test
  func categorySpendChartIsNilBelowTwoPoints() {
    let points = [
      MonthlySpendPoint(month: "202606", date: InsightTestSupport.date(2026, 6, 1), magnitude: 400)
    ]
    #expect(
      InsightChartBuilders.categorySpend(
        points: points, reportingCurrency: currency, highlightMonth: "202606") == nil)
  }

  private func balance(
    _ day: Int, total: Decimal, forecast: Bool, netWorth: Decimal? = nil
  ) -> DailyBalance {
    let amount = InstrumentAmount(quantity: total, instrument: currency)
    let zero = InstrumentAmount.zero(instrument: currency)
    return DailyBalance(
      date: InsightTestSupport.date(2026, 6, day),
      balance: amount,
      earmarked: zero,
      availableFunds: amount,
      investments: zero,
      investmentValue: nil,
      netWorth: InstrumentAmount(quantity: netWorth ?? total, instrument: currency),
      bestFit: nil,
      isForecast: forecast)
  }

  @Test
  func netWorthTrendUsesNetWorthValues() throws {
    let balances = [
      balance(1, total: 90_000, forecast: false),
      balance(15, total: 95_000, forecast: false),
      balance(30, total: 91_000, forecast: false, netWorth: 101_000),
    ]
    let chart = try #require(
      InsightChartBuilders.netWorthTrend(balances, reportingCurrency: currency))
    #expect(chart.kind == .line)
    #expect(chart.series.first?.role == .primary)
    #expect(chart.series.first?.points.count == 3)
    #expect(chart.series.first?.points.last?.value == 101_000)
    #expect(chart.highlight?.value == 101_000)
  }

  @Test
  func savingsRateChartIsPercentUnit() throws {
    let points = [
      InsightChart.Point(date: InsightTestSupport.date(2026, 3, 31), value: 0.10),
      InsightChart.Point(date: InsightTestSupport.date(2026, 4, 30), value: 0.15),
      InsightChart.Point(date: InsightTestSupport.date(2026, 5, 31), value: 0.22),
    ]
    let chart = try #require(InsightChartBuilders.savingsRate(points: points))
    #expect(chart.kind == .line)
    #expect(chart.unit == .percent)
    #expect(chart.xAxis == .monthly)
    #expect(chart.highlight?.value == 0.22)
  }

  @Test
  func balanceForecastSplitsActualAndProjected() throws {
    let balances = [
      balance(1, total: 1000, forecast: false),
      balance(2, total: 900, forecast: false),
      balance(3, total: 400, forecast: true),
      balance(4, total: 700, forecast: true),
    ]
    let chart = try #require(
      InsightChartBuilders.balanceForecast(
        balances, reportingCurrency: currency, highlight: InsightTestSupport.date(2026, 6, 3)))

    #expect(chart.kind == .line)
    #expect(chart.unit == .currency(currency))
    #expect(chart.xAxis == .daily)
    #expect(chart.series.contains { $0.role == .primary })
    #expect(chart.series.contains { $0.role == .projected })
    #expect(chart.highlight?.value == 400)

    let actual = try #require(chart.series.first { $0.role == .primary })
    #expect(actual.points.count == 2)
    let projected = try #require(chart.series.first { $0.role == .projected })
    // Bridge: last actual (day 2 = 900) prepended, then day 3 (400), day 4 (700).
    #expect(projected.points.count == 3)
    #expect(projected.points.first?.value == 900)
  }

  @Test
  func earmarkBurndownProjectsBeyondBudget() throws {
    let start = InsightTestSupport.date(2026, 6, 1)
    let now = InsightTestSupport.date(2026, 6, 15)
    let end = InsightTestSupport.date(2026, 6, 30)
    let chart = try #require(
      InsightChartBuilders.earmarkBurndown(
        budget: 1000,
        current: InsightChart.Point(date: now, value: 300),
        projectedRemaining: -400,
        window: DateInterval(start: start, end: end),
        reportingCurrency: currency))

    #expect(chart.kind == .line)
    #expect(chart.unit == .currency(currency))
    #expect(chart.series.contains { $0.role == .baseline })
    #expect(chart.series.contains { $0.role == .primary })
    #expect(chart.series.contains { $0.role == .projected })
    let projected = try #require(chart.series.first { $0.role == .projected })
    #expect(projected.points.last?.value == -400)  // budget(1000) - projected(1400)
    #expect(chart.xAxis == .daily)
    #expect(chart.highlight?.value == 300)  // current remaining = budget(1000) - spent(700)
    let baseline = try #require(chart.series.first { $0.role == .baseline })
    #expect(baseline.points.count == 2)
    #expect(chart.series.first { $0.role == .primary }?.points.count == 1)
  }

  @Test
  func earmarkBurndownIsNilForZeroBudget() {
    #expect(
      InsightChartBuilders.earmarkBurndown(
        budget: 0,
        current: InsightChart.Point(date: InsightTestSupport.now, value: 0),
        projectedRemaining: 0,
        window: DateInterval(
          start: InsightTestSupport.date(2026, 6, 1), end: InsightTestSupport.date(2026, 6, 30)),
        reportingCurrency: currency) == nil)
  }
}
