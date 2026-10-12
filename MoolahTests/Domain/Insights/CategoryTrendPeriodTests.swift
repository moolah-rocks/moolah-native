import Foundation
import Testing

@testable import Moolah

@Suite("Category trend evidence periods")
struct CategoryTrendPeriodTests {
  private let electricity = Category(
    id: makeUUID("4D40F996-E998-4E10-A073-1ECBB7524E03"), name: "Electricity")
  private let months = [
    "202509", "202510", "202511", "202512", "202601", "202602", "202603",
    "202604", "202605", "202606", "202607", "202608", "202609", "202610",
  ]

  @Test(arguments: [true, false])
  func trendDescriptionUsesEndDate(rising: Bool) throws {
    let insight = try trend(rising: rising)
    let description = InsightDescriptionComposer.compose(
      kind: insight.kind, title: insight.title, facts: insight.facts)
    #expect(description.contains("12 months through Oct 13, 2026"))
    #expect(!description.contains("Sep 14"))
  }

  @Test(arguments: [true, false])
  func viewingTrendFiltersToAnalysedFinancialMonths(rising: Bool) throws {
    let insight = try trend(rising: rising)
    let filter = try #require(insight.references.transactionFilter)
    let range = try #require(filter.dateRange)
    #expect(range.lowerBound == InsightTestSupport.date(2025, 10, 14))
    #expect(range.contains(InsightTestSupport.date(2026, 10, 14).addingTimeInterval(-0.001)))
    #expect(!range.contains(InsightTestSupport.date(2026, 10, 14)))
    #expect(filter.categoryIds == [electricity.id])
    #expect(filter.transactionTypes == [.expense])
    #expect(filter.scheduled == .nonScheduledOnly)
    #expect(filter.dateRangeCalendar == .utc)
    #expect(InsightNavigationTarget.target(for: insight) == .transactions(filter))
  }

  @Test
  func viewingUncategorizedTrendKeepsUncategorizedExpenseScope() throws {
    let insight = try trend(uncategorized: true)
    let filter = try #require(insight.references.transactionFilter)
    #expect(filter.categoryIds.isEmpty)
    #expect(filter.uncategorisedLegType == .expense)
    #expect(filter.dateRange != nil)
    #expect(InsightNavigationTarget.target(for: insight) == .transactions(filter))
  }

  @Test
  func trendEvidenceStartsAfterUnavailableMonth() throws {
    var breakdown = rows(categoryId: electricity.id, rising: true)
    breakdown[7] = InsightTestSupport.breakdownRow(
      800, categoryId: electricity.id, month: months[7], hasUnavailableData: true)
    let insight = try #require(
      CategoryTrendInsight.detect(
        breakdown: breakdown, categories: Categories(from: [electricity]),
        context: InsightTestSupport.context(monthEnd: 13)
      ).first)
    #expect(
      insight.references.transactionFilter?.dateRange?.lowerBound
        == InsightTestSupport.date(2026, 4, 14))
  }

  private func trend(rising: Bool = false, uncategorized: Bool = false) throws -> Insight {
    let insight = CategoryTrendInsight.detect(
      breakdown: rows(categoryId: uncategorized ? nil : electricity.id, rising: rising),
      categories: Categories(from: [electricity]),
      context: InsightTestSupport.context(monthEnd: 13))
    return try #require(insight.first)
  }

  private func rows(categoryId: UUID?, rising: Bool) -> [ExpenseBreakdown] {
    months.enumerated().map { index, month in
      InsightTestSupport.breakdownRow(
        Decimal(rising ? 100 + index * 100 : 1500 - index * 100),
        categoryId: categoryId, month: month)
    }
  }
}
