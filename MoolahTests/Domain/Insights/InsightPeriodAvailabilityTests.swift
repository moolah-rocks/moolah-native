import Foundation
import Testing

@testable import Moolah

@Suite("Insight period labels and availability")
struct InsightPeriodAvailabilityTests {
  private let context = InsightTestSupport.context()

  @Test
  func financialMonthDescriptionNamesCustomCutoffRange() {
    let cutoffContext = InsightTestSupport.context(monthEnd: 25)
    #expect(cutoffContext.formattedFinancialMonth("202602") == "Jan 26 – Feb 25, 2026")
  }

  @Test(arguments: [29, 30])
  func financialMonthDescriptionClampsCutoffAfterFebruary(_ cutoff: Int) {
    let cutoffContext = InsightTestSupport.context(monthEnd: cutoff)
    #expect(
      cutoffContext.formattedFinancialMonth("202603")
        == "Mar 1 – Mar \(cutoff), 2026")
  }

  @Test
  func financialMonthDescriptionsAreTimeZoneInvariant() throws {
    let zoneIds = [
      "America/Los_Angeles",
      "UTC",
      "Australia/Brisbane",
      "Pacific/Kiritimati",
    ]
    for zoneId in zoneIds {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: zoneId))
      let calendarMonth = InsightContext(
        now: InsightTestSupport.now,
        reportingCurrency: InsightTestSupport.currency,
        calendar: calendar,
        financialMonthEnd: 31)
      let cutoffMonth = InsightContext(
        now: InsightTestSupport.now,
        reportingCurrency: InsightTestSupport.currency,
        calendar: calendar,
        financialMonthEnd: 25)

      #expect(calendarMonth.formattedFinancialMonth("202602") == "February 2026")
      #expect(cutoffMonth.formattedFinancialMonth("202602") == "Jan 26 – Feb 25, 2026")
    }
  }

  @Test
  func monthOverMonthSuppressesUnavailableComparison() {
    let monthly = [
      InsightTestSupport.monthly(month: "202604", income: 5000, expense: 100),
      InsightTestSupport.monthly(
        month: "202605", income: 5000, expense: 130, hasUnavailableData: true),
    ]
    #expect(PeriodComparisonInsights.detect(monthly: monthly, context: context).isEmpty)
  }

  @Test
  func monthOverMonthOmitsChartWithOlderUnavailableMonth() throws {
    let monthly = [
      InsightTestSupport.monthly(
        month: "202603", income: 5000, expense: 90, hasUnavailableData: true),
      InsightTestSupport.monthly(month: "202604", income: 5000, expense: 100),
      InsightTestSupport.monthly(month: "202605", income: 5000, expense: 130),
    ]
    let insight = try #require(
      PeriodComparisonInsights.detect(monthly: monthly, context: context).first)
    #expect(insight.chart == nil)
  }
}
