import Foundation
import Testing

@testable import Moolah

@Suite("Unavailable spend insights")
struct UnavailableSpendInsightTests {
  private let context = InsightTestSupport.context()

  @Test
  func interiorUnavailableMonthSuppressesTrendAndAnomaly() {
    let dining = Category(name: "Dining")
    let categories = Categories(from: [dining])
    let trend = breakdown(
      magnitudes: [100, 140, 180, 220, 260, 300],
      months: ["202601", "202602", "202603", "202604", "202605", "202606"],
      categoryId: dining.id,
      unavailableIndex: 2)
    #expect(
      CategoryTrendInsight.detect(
        breakdown: trend, categories: categories, context: context
      ).isEmpty)

    let anomaly = breakdown(
      magnitudes: [100, 105, 98, 102, 100, 103, 99, 400],
      months: [
        "202511", "202512", "202601", "202602", "202603", "202604", "202605", "202606",
      ],
      categoryId: dining.id,
      unavailableIndex: 3)
    #expect(
      CategoryAnomalyInsight.detect(
        breakdown: anomaly, categories: categories, context: context
      ).isEmpty)
  }

  @Test
  func oldUnavailableMonthDoesNotSuppressLaterContiguousTrend() {
    let dining = Category(name: "Dining")
    let categories = Categories(from: [dining])
    var trend = [
      InsightTestSupport.breakdownRow(
        50,
        categoryId: dining.id,
        month: "201801",
        hasUnavailableData: true)
    ]
    trend += breakdown(
      magnitudes: [100, 140, 180, 220, 260, 300],
      months: ["202601", "202602", "202603", "202604", "202605", "202606"],
      categoryId: dining.id,
      unavailableIndex: -1)

    let insights = CategoryTrendInsight.detect(
      breakdown: trend, categories: categories, context: context)

    #expect(insights.contains { $0.kind == .categoryTrendRising })
  }

  private func breakdown(
    magnitudes: [Decimal],
    months: [String],
    categoryId: UUID,
    unavailableIndex: Int
  ) -> [ExpenseBreakdown] {
    zip(months, magnitudes).enumerated().map { index, pair in
      InsightTestSupport.breakdownRow(
        pair.1,
        categoryId: categoryId,
        month: pair.0,
        hasUnavailableData: index == unavailableIndex)
    }
  }
}
