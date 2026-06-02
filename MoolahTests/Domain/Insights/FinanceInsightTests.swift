import Foundation
import Testing

@testable import Moolah

@Suite("Budget, cash-flow & investment insights")
struct FinanceInsightTests {
  private let context = InsightTestSupport.context()

  private func profitLoss(
    _ name: String, invested: Decimal, value: Decimal, unrealized: Decimal
  ) -> InstrumentProfitLoss {
    InstrumentProfitLoss(
      instrument: Instrument.stock(ticker: name, exchange: "NASDAQ", name: name),
      currentQuantity: 1, totalInvested: invested, currentValue: value,
      realizedGain: 0, unrealizedGain: unrealized)
  }

  // MARK: - Earmarks

  @Test
  func earmarkOverspendProjection() throws {
    let earmark = EarmarkSnapshot(
      id: UUID(), name: "Groceries", balance: InsightTestSupport.amount(20),
      spent: InsightTestSupport.amount(80), budget: InsightTestSupport.amount(100),
      savingsStartDate: InsightTestSupport.daysAgo(15),
      savingsEndDate: InsightTestSupport.daysAgo(-15))
    let insights = EarmarkBudgetInsights.detect(earmarks: [earmark], context: context)
    let overspend = try #require(insights.first { $0.kind == .earmarkBurndownProjection })
    #expect(overspend.actionability == .act)
  }

  @Test
  func earmarkUnderspendIsPositive() throws {
    let earmark = EarmarkSnapshot(
      id: UUID(), name: "Dining", balance: InsightTestSupport.amount(80),
      spent: InsightTestSupport.amount(20), budget: InsightTestSupport.amount(100),
      savingsStartDate: InsightTestSupport.daysAgo(60),
      savingsEndDate: InsightTestSupport.daysAgo(-30))
    let insights = EarmarkBudgetInsights.detect(earmarks: [earmark], context: context)
    let underspend = try #require(insights.first { $0.kind == .earmarkUnderspend })
    #expect(underspend.framing == .positive)
  }

  @Test
  func savingsGoalProjectsCompletion() throws {
    let earmark = EarmarkSnapshot(
      id: UUID(), name: "Holiday", balance: InsightTestSupport.amount(250),
      savingsGoal: InsightTestSupport.amount(1000), saved: InsightTestSupport.amount(250),
      savingsStartDate: InsightTestSupport.daysAgo(100))
    let insights = SavingsGoalInsight.detect(earmarks: [earmark], context: context)
    let eta = try #require(insights.first { $0.kind == .savingsGoalETA })
    #expect(eta.framing == .positive)
  }

  @Test
  func savingsGoalReached() throws {
    let earmark = EarmarkSnapshot(
      id: UUID(), name: "Emergency", balance: InsightTestSupport.amount(1000),
      savingsGoal: InsightTestSupport.amount(1000), saved: InsightTestSupport.amount(1000))
    let insights = SavingsGoalInsight.detect(earmarks: [earmark], context: context)
    let reached = try #require(insights.first)
    #expect(reached.framing == .positive)
    #expect(reached.title.contains("reached"))
  }

  // MARK: - Net worth & investments

  @Test
  func netWorthMilestoneCrossing() throws {
    let balances = [
      DailyBalance(date: InsightTestSupport.daysAgo(40), balance: InsightTestSupport.amount(9500)),
      DailyBalance(date: InsightTestSupport.daysAgo(0), balance: InsightTestSupport.amount(10500)),
    ]
    let insights = NetWorthInsights.detect(dailyBalances: balances, context: context)
    let milestone = try #require(insights.first)
    #expect(milestone.kind == .netWorthMilestone)
    #expect(milestone.framing == .positive)
  }

  @Test
  func concentrationRiskFlagsDominantHolding() throws {
    let positions = [
      profitLoss("AAA", invested: 8000, value: 8000, unrealized: 0),
      profitLoss("BBB", invested: 2000, value: 2000, unrealized: 0),
    ]
    let insights = InvestmentInsights.detect(
      profitLoss: positions, capitalGains: [], context: context)
    #expect(insights.contains { $0.kind == .investmentConcentrationRisk })
  }

  @Test
  func topAndBottomPerformers() {
    let positions = [
      profitLoss("WIN", invested: 1000, value: 1300, unrealized: 300),
      profitLoss("LOSE", invested: 1000, value: 800, unrealized: -200),
    ]
    let insights = InvestmentInsights.detect(
      profitLoss: positions, capitalGains: [], context: context)
    #expect(insights.contains { $0.kind == .topPerformer })
    #expect(insights.contains { $0.kind == .bottomPerformer })
  }

  // MARK: - Liquidity

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
  }

  @Test
  func feeSpendSumsAnnualFees() throws {
    // Per-category 365-day spend rows (negative for spend); only the two
    // fee-category rows should be summed, the rent row ignored.
    let feeCategorySpend = [
      CategorySpendSummary(
        categoryId: UUID(), categoryPath: "Banking:Fees",
        total: InsightTestSupport.amount(-35), legCount: 1),
      CategorySpendSummary(
        categoryId: UUID(), categoryPath: "Banking:Account Fee",
        total: InsightTestSupport.amount(-15), legCount: 1),
      CategorySpendSummary(
        categoryId: UUID(), categoryPath: "Housing:Rent",
        total: InsightTestSupport.amount(-200), legCount: 1),
    ]
    let insights = SavingsOpportunityInsights.feeSpend(
      feeCategorySpend: feeCategorySpend, context: context)
    let fees = try #require(insights.first)
    #expect(fees.kind == .feeSpend)
  }
}
