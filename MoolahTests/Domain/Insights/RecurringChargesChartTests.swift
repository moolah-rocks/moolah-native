import Foundation
import Testing

@testable import Moolah

@Suite("Recurring-charge chart builder")
struct RecurringChargesChartTests {
  private let currency = InsightTestSupport.currency

  @Test
  func recurringChargesPlotsExpenseMagnitudeAndHighlightsLatest() throws {
    let dates = [
      InsightTestSupport.date(2026, 3, 1),
      InsightTestSupport.date(2026, 4, 1),
      InsightTestSupport.date(2026, 5, 1),
    ]
    // Expense stream: signed negative; the chart plots positive charge magnitude
    // so a price hike reads as a rising line.
    let chart = try #require(
      InsightChartBuilders.recurringCharges(
        dates: dates, amounts: [-10, -10, -12], reportingCurrency: currency, isIncome: false))

    #expect(chart.kind == .line)
    #expect(chart.unit == .currency(currency))
    #expect(chart.xAxis == .daily)
    #expect(chart.series.first?.id == "charges")
    #expect(chart.series.first?.points.map(\.value) == [10, 10, 12])
    #expect(chart.highlight?.value == 12)
    #expect(chart.highlight?.date == InsightTestSupport.date(2026, 5, 1))
  }

  @Test
  func recurringChargesKeepsIncomePositive() throws {
    let dates = [InsightTestSupport.date(2026, 4, 1), InsightTestSupport.date(2026, 5, 1)]
    let chart = try #require(
      InsightChartBuilders.recurringCharges(
        dates: dates, amounts: [3000, 3300], reportingCurrency: currency, isIncome: true))
    #expect(chart.series.first?.points.map(\.value) == [3000, 3300])
    #expect(chart.highlight?.value == 3300)
  }

  @Test
  func recurringChargesIsNilBelowTwoPoints() {
    #expect(
      InsightChartBuilders.recurringCharges(
        dates: [InsightTestSupport.now], amounts: [-10], reportingCurrency: currency,
        isIncome: false) == nil)
  }

  @Test
  func recurringChargesIsNilWhenDatesAndAmountsMisalign() {
    #expect(
      InsightChartBuilders.recurringCharges(
        dates: [InsightTestSupport.date(2026, 4, 1), InsightTestSupport.date(2026, 5, 1)],
        amounts: [-10], reportingCurrency: currency, isIncome: false) == nil)
  }
}
