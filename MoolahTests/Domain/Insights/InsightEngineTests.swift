import Foundation
import Testing

@testable import Moolah

@Suite("InsightEngine")
struct InsightEngineTests {
  private let context = InsightTestSupport.context()

  private func sampleInput() -> InsightInput {
    var legs: [InsightTransaction] = []
    // A monthly subscription with a price hike on the latest charge.
    let netflixAmounts: [Decimal] = [10, 10, 10, 12]
    for (index, magnitude) in netflixAmounts.enumerated() {
      legs.append(
        InsightTestSupport.expense(magnitude, payee: "Netflix", daysAgo: (3 - index) * 30))
    }
    // Recurring fortnightly income.
    for index in 0..<4 {
      legs.append(
        InsightTestSupport.income(2500, payee: "ACME Payroll", daysAgo: index * 14))
    }

    let balances = [
      DailyBalance(date: InsightTestSupport.daysAgo(40), balance: InsightTestSupport.amount(9400)),
      DailyBalance(date: InsightTestSupport.now, balance: InsightTestSupport.amount(10200)),
    ]
    let underspend = EarmarkSnapshot(
      id: UUID(), name: "Dining", balance: InsightTestSupport.amount(80),
      spent: InsightTestSupport.amount(20), budget: InsightTestSupport.amount(100),
      savingsStartDate: InsightTestSupport.daysAgo(60),
      savingsEndDate: InsightTestSupport.daysAgo(-30))
    let monthly = ["202603", "202604", "202605"].map {
      InsightTestSupport.monthly(month: $0, income: 5000, expense: 3000)
    }

    return InsightInput(
      context: context,
      recentCandidates: InsightTestSupport.recentCandidates(from: legs),
      dailyTotals: InsightTestSupport.dailyTotals(from: legs),
      payees: InsightTestSupport.payees(from: legs),
      categorySamples: InsightTestSupport.categorySamples(from: legs),
      monthly: monthly,
      dailyBalances: balances,
      earmarks: [underspend],
      categories: Categories(from: []))
  }

  @Test
  func detectAllProducesMultipleKinds() {
    let insights = InsightEngine().detectAll(sampleInput())
    let kinds = Set(insights.map(\.kind))
    #expect(insights.count >= 3)
    #expect(kinds.contains(.netWorthMilestone))
    #expect(kinds.contains(.earmarkUnderspend))
  }

  @Test
  func generateRespectsCapAndIncludesPositive() {
    let ranked = InsightEngine().generate(sampleInput(), displayCap: 5)
    #expect(ranked.count <= 5)
    #expect(ranked.contains { $0.insight.framing == .positive })
  }

  @Test
  func emptyInputProducesNoInsights() {
    let input = InsightInput(context: context)
    #expect(InsightEngine().detectAll(input).isEmpty)
  }
}
