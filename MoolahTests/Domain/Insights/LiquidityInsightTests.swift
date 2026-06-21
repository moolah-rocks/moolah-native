import Foundation
import Testing

@testable import Moolah

@Suite("Liquidity insights — runway & idle cash")
struct LiquidityInsightTests {
  private let context = InsightTestSupport.context()

  @Test
  func idleCashAlert() throws {
    let balances = [
      DailyBalance(date: InsightTestSupport.now, balance: InsightTestSupport.amount(20000))
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 4000, expense: 2000)
    }
    let insights = LiquidityInsights.idleCash(
      dailyBalances: balances, monthly: monthly, context: context)
    let idle = try #require(insights.first)
    #expect(idle.kind == .idleCashAlert)
    #expect(idle.actionability == .act)
  }

  @Test
  func runwayWarnsWhenBurning() throws {
    let balances = [
      DailyBalance(date: InsightTestSupport.now, balance: InsightTestSupport.amount(10000))
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 1000, expense: 3000)
    }
    let insights = LiquidityInsights.runway(
      dailyBalances: balances, monthly: monthly, context: context)
    let runway = try #require(insights.first)
    #expect(runway.kind == .runwayEstimate)
    // A single balance point is too sparse for `balanceForecast`, so this
    // runway falls back to a graph-less row.
    #expect(runway.chart == nil)
  }

  @Test
  func runwayAttachesBalanceForecastChart() throws {
    let balances = [
      InsightTestSupport.balance(offsetDays: 10, total: 12000, forecast: false),
      InsightTestSupport.balance(offsetDays: 0, total: 10000, forecast: false),
      InsightTestSupport.balance(offsetDays: -10, total: 8000, forecast: true),
      InsightTestSupport.balance(offsetDays: -20, total: 6000, forecast: true),
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 1000, expense: 3000)
    }
    let runway = try #require(
      LiquidityInsights.runway(dailyBalances: balances, monthly: monthly, context: context).first)
    let chart = try #require(runway.chart)
    #expect(chart.unit == .currency(InsightTestSupport.currency))
    #expect(chart.series.contains { $0.role == .primary })
    #expect(chart.series.contains { $0.role == .projected })
    // Highlight marks the latest actual reading ("you are here" = $10,000 now).
    #expect(chart.highlight?.value == 10000)
  }

  @Test
  func idleCashAttachesBalanceForecastChart() throws {
    let balances = [
      InsightTestSupport.balance(offsetDays: 10, total: 19000, forecast: false),
      InsightTestSupport.balance(offsetDays: 0, total: 20000, forecast: false),
      InsightTestSupport.balance(offsetDays: -10, total: 20500, forecast: true),
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 4000, expense: 2000)
    }
    let idle = try #require(
      LiquidityInsights.idleCash(dailyBalances: balances, monthly: monthly, context: context).first)
    let chart = try #require(idle.chart)
    #expect(chart.unit == .currency(InsightTestSupport.currency))
    #expect(chart.highlight?.value == 20000)
  }

  @Test
  func idleCashUsesAvailableFundsNotGrossBalance() throws {
    // $20k current funds, $8k earmarked → $12k available. Average monthly
    // spend $2k × 3 = $6k buffer, so the idle excess is measured from the
    // available $12k (excess $6k), not the gross $20k (which would be $14k).
    let balances = [
      InsightTestSupport.balance(offsetDays: 0, total: 20000, earmarked: 8000, forecast: false)
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 4000, expense: 2000)
    }
    let idle = try #require(
      LiquidityInsights.idleCash(dailyBalances: balances, monthly: monthly, context: context).first)

    #expect(idle.monetaryImpact?.quantity == 6000)
    let labels = Dictionary(uniqueKeysWithValues: idle.facts.map { ($0.label, $0.value) })
    #expect(labels["Available funds"] == InsightTestSupport.amount(12000).formatted)
    #expect(labels["Average monthly spend"] == InsightTestSupport.amount(2000).formatted)
    #expect(labels["Idle excess"] == InsightTestSupport.amount(6000).formatted)
    #expect(labels["Liquid cash"] == nil)
    // The buffer fact makes its 3-months-of-spending basis visible.
    #expect(idle.facts.contains { $0.label == "Suggested buffer (3 months' spending)" })
  }

  @Test
  func runwayUsesAvailableFundsNotGrossBalance() throws {
    // $10k current funds, $4k earmarked → $6k available. Burning $2k/month
    // leaves 3 months of runway off the available $6k, not 5 off the gross.
    let balances = [
      InsightTestSupport.balance(offsetDays: 0, total: 10000, earmarked: 4000, forecast: false)
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 1000, expense: 3000)
    }
    let runway = try #require(
      LiquidityInsights.runway(dailyBalances: balances, monthly: monthly, context: context).first)

    let labels = Dictionary(uniqueKeysWithValues: runway.facts.map { ($0.label, $0.value) })
    #expect(labels["Available funds"] == InsightTestSupport.amount(6000).formatted)
    #expect(labels["Liquid cash"] == nil)
    #expect(runway.facts.contains { $0.label == "Runway" && $0.value == "3 months" })
  }

  @Test
  func liquidityChartPlotsAvailableFunds() throws {
    // Latest actual day: $20k gross, $8k earmarked → $12k available. The
    // companion chart's highlight must mark the available $12k, not $20k.
    let balances = [
      InsightTestSupport.balance(offsetDays: 10, total: 19000, earmarked: 8000, forecast: false),
      InsightTestSupport.balance(offsetDays: 0, total: 20000, earmarked: 8000, forecast: false),
      InsightTestSupport.balance(offsetDays: -10, total: 20500, earmarked: 8000, forecast: true),
    ]
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 4000, expense: 2000)
    }
    let idle = try #require(
      LiquidityInsights.idleCash(dailyBalances: balances, monthly: monthly, context: context).first)
    let chart = try #require(idle.chart)
    #expect(chart.highlight?.value == 12000)
    #expect(chart.series.contains { $0.label == "Available funds" })
  }
}
