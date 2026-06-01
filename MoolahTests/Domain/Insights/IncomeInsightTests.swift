import Foundation
import Testing

@testable import Moolah

@Suite("Income insights")
struct IncomeInsightTests {
  private let context = InsightTestSupport.context()
  private let calendar = InsightTestSupport.calendar

  private func streams(_ transactions: [InsightTransaction]) -> [DetectedSubscription] {
    SubscriptionDetector.detect(in: transactions, incomeStreams: true, calendar: calendar)
  }

  @Test
  func projectsNextPaycheck() throws {
    let transactions = [
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 14),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 0),
    ]
    let insights = IncomeInsights.detect(incomeStreams: streams(transactions), context: context)
    #expect(insights.contains { $0.kind == .paycheckTimingPattern })
  }

  @Test
  func flagsMissingPaycheck() throws {
    let transactions = [
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 48),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 34),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 20),
    ]
    let insights = IncomeInsights.detect(incomeStreams: streams(transactions), context: context)
    let missing = try #require(insights.first { $0.kind == .missingPaycheckAlert })
    #expect(missing.actionability == .act)
    // When pay is missing, the forward-looking timing insight is suppressed.
    #expect(!insights.contains { $0.kind == .paycheckTimingPattern })
  }

  @Test
  func reportsStableIncome() throws {
    let transactions = [
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 14),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 0),
    ]
    let insights = IncomeInsights.detect(incomeStreams: streams(transactions), context: context)
    let stability = try #require(insights.first { $0.kind == .incomeStabilityScore })
    #expect(stability.framing == .positive)
  }
}
