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

  @Test(arguments: ["America/Los_Angeles", "UTC", "Australia/Brisbane", "Pacific/Kiritimati"])
  func financialMonthEvidenceIsTimeZoneInvariant(zoneId: String) throws {
    var calendar = Calendar.utc
    calendar.timeZone = try #require(TimeZone(identifier: zoneId))
    let cases = [
      (
        13, "202610", InsightTestSupport.date(2026, 9, 14), InsightTestSupport.date(2026, 10, 14),
        "Oct 13, 2026"
      ),
      (
        31, "202602", InsightTestSupport.date(2026, 2, 1), InsightTestSupport.date(2026, 3, 1),
        "Feb 28, 2026"
      ),
      (
        30, "202603", InsightTestSupport.date(2026, 3, 1), InsightTestSupport.date(2026, 3, 31),
        "Mar 30, 2026"
      ),
      (
        29, "202402", InsightTestSupport.date(2024, 1, 30), InsightTestSupport.date(2024, 3, 1),
        "Feb 29, 2024"
      ),
      (
        1, "202601", InsightTestSupport.date(2025, 12, 2), InsightTestSupport.date(2026, 1, 2),
        "Jan 1, 2026"
      ),
    ]
    for (cutoff, key, start, nextDay, endText) in cases {
      let context = InsightContext(
        now: InsightTestSupport.now, reportingCurrency: InsightTestSupport.currency,
        calendar: calendar, financialMonthEnd: cutoff)
      let range = try #require(context.financialMonthDateRange(key))
      #expect(range.lowerBound == start)
      #expect(range.contains(nextDay.addingTimeInterval(-0.001)))
      #expect(!range.contains(nextDay))
      #expect(context.formattedFinancialMonthEnd(key) == endText)
    }
  }

  @Test
  func savingsRateDescriptionUsesEndDate() throws {
    let monthly = (1...6).map { month in
      InsightTestSupport.monthly(
        month: String(format: "2026%02d", month), income: 5000,
        expense: Decimal(4000 - month * 400))
    }
    let insight = try #require(
      SavingsRateInsight.detect(
        monthly: monthly,
        context: InsightTestSupport.context(
          now: InsightTestSupport.date(2026, 7, 1), monthEnd: 13)
      ).first)
    let description = InsightDescriptionComposer.compose(
      kind: insight.kind, title: insight.title, facts: insight.facts)
    #expect(description.contains("6 complete months through Jun 13, 2026"))
  }

  @Test
  func monthOverMonthSuppressesUnavailableComparison() {
    let monthly = [
      InsightTestSupport.monthlySpending(month: "202604", expense: 100),
      InsightTestSupport.monthlySpending(
        month: "202605", expense: 130, hasUnavailableData: true),
    ]
    #expect(PeriodComparisonInsights.detect(monthly: monthly, context: context).isEmpty)
  }

  @Test
  func monthOverMonthOmitsChartWithOlderUnavailableMonth() throws {
    let monthly = [
      InsightTestSupport.monthlySpending(
        month: "202603", expense: 90, hasUnavailableData: true),
      InsightTestSupport.monthlySpending(month: "202604", expense: 100),
      InsightTestSupport.monthlySpending(month: "202605", expense: 130),
    ]
    let insight = try #require(
      PeriodComparisonInsights.detect(monthly: monthly, context: context).first)
    #expect(insight.chart == nil)
  }
}
