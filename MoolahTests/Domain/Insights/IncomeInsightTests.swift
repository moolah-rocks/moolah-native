import Foundation
import Testing

@testable import Moolah

@Suite("Income insights")
struct IncomeInsightTests {
  private let context = InsightTestSupport.context()
  private let calendar = InsightTestSupport.calendar

  private func streams(_ legs: [InsightTransaction]) -> [DetectedSubscription] {
    SubscriptionDetector.detect(
      payees: InsightTestSupport.payees(from: legs), incomeStreams: true, calendar: calendar)
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

  @Test
  func paycheckTimingAndStabilityAttachIncomeCharts() throws {
    let transactions = [
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 28),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 14),
      InsightTestSupport.income(3000, payee: "ACME Payroll", daysAgo: 0),
    ]
    let insights = IncomeInsights.detect(incomeStreams: streams(transactions), context: context)

    let timing = try #require(insights.first { $0.kind == .paycheckTimingPattern })
    let timingChart = try #require(timing.chart)
    #expect(timingChart.kind == .line)
    #expect(timingChart.unit == .currency(InsightTestSupport.currency))
    #expect(timingChart.highlight?.value == 3000)

    let stability = try #require(insights.first { $0.kind == .incomeStabilityScore })
    let stabilityChart = try #require(stability.chart)
    #expect(stabilityChart.series.first?.points.count == 3)
    #expect(stabilityChart.highlight?.value == 3000)
  }
}
