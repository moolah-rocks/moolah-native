import Foundation
import Testing

@testable import Moolah

@Suite("Monthly category-spend chart builder")
struct MonthlyCategorySpendChartTests {
  private let currency = InsightTestSupport.currency

  @Test
  func monthlyCategorySpendSumsFeeCategoriesPerMonth() throws {
    let feesA = UUID()
    let feesB = UUID()
    let rent = UUID()
    let breakdown = [
      InsightTestSupport.breakdownRow(20, categoryId: feesA, month: "202604"),
      InsightTestSupport.breakdownRow(5, categoryId: feesB, month: "202604"),
      InsightTestSupport.breakdownRow(30, categoryId: feesA, month: "202605"),
      // Rent is not a fee category and must not contribute.
      InsightTestSupport.breakdownRow(500, categoryId: rent, month: "202605"),
    ]
    let chart = try #require(
      InsightChartBuilders.monthlyCategorySpend(
        expenseBreakdown: breakdown, categoryIds: [feesA, feesB], reportingCurrency: currency,
        seriesLabel: "Fees"))

    #expect(chart.kind == .bar)
    #expect(chart.unit == .currency(currency))
    #expect(chart.xAxis == .monthly)
    #expect(chart.series.first?.id == "fees")
    #expect(chart.series.first?.label == "Fees")
    #expect(chart.series.first?.points.count == 2)
    // April sums both fee categories (20 + 5); May has only feesA (30).
    #expect(chart.series.first?.points.first?.value == 25)
    #expect(chart.highlight?.value == 30)
    // The point date is the financial-month positioning token (noon UTC,
    // zone-invariant), not a midnight instant — see FinancialMonth.date(forKey:).
    #expect(chart.highlight?.date == FinancialMonth.date(forKey: "202605"))
  }

  @Test
  func monthlyCategorySpendIsNilWhenNoFeeRows() {
    let breakdown = [InsightTestSupport.breakdownRow(500, categoryId: UUID(), month: "202605")]
    #expect(
      InsightChartBuilders.monthlyCategorySpend(
        expenseBreakdown: breakdown, categoryIds: [UUID()], reportingCurrency: currency,
        seriesLabel: "Fees") == nil)
  }

  @Test
  func monthlyCategorySpendIsNilBelowTwoMonths() {
    let fees = UUID()
    let breakdown = [InsightTestSupport.breakdownRow(20, categoryId: fees, month: "202605")]
    #expect(
      InsightChartBuilders.monthlyCategorySpend(
        expenseBreakdown: breakdown, categoryIds: [fees], reportingCurrency: currency,
        seriesLabel: "Fees") == nil)
  }
}
