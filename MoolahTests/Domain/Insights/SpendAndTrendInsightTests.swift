import Foundation
import Testing

@testable import Moolah

@Suite("Spend & trend insights")
struct SpendAndTrendInsightTests {
  private let context = InsightTestSupport.context()
  private let emptyCategories = Categories(from: [])

  @Test
  func largeTransactionAnomalyFlagsOutlier() throws {
    let dining = UUID()
    var baseline: [InsightTransaction] = []
    let normals: [Decimal] = [18, 19, 20, 21, 22, 19, 20, 21, 18]
    for (index, magnitude) in normals.enumerated() {
      baseline.append(
        InsightTestSupport.expense(
          magnitude, payee: "Cafe", daysAgo: index * 4 + 1, categoryId: dining,
          categoryPath: "Dining"))
    }
    let outlier = InsightTestSupport.expense(
      200, payee: "Steakhouse", daysAgo: 2, categoryId: dining, categoryPath: "Dining")

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [outlier],
      categorySamples: InsightTestSupport.categorySamples(from: baseline + [outlier]),
      categories: emptyCategories, context: context)
    let anomaly = try #require(insights.first { $0.kind == .largeTransactionAnomaly })
    #expect(anomaly.references.transactionIds.count == 1)
    #expect(anomaly.surprise > 0.9)
  }

  @Test
  func newMerchantAlertFiresForLargeFirstCharge() {
    // Categorised history establishes the top-decile magnitude baseline and
    // the "Groceries" payee; the new "Fancy Restaurant" charge is novel.
    let groceriesCategory = UUID()
    var history: [InsightTransaction] = []
    for index in 0..<12 {
      history.append(
        InsightTestSupport.expense(
          Decimal(20 + index), payee: "Groceries", daysAgo: 20 + index,
          categoryId: groceriesCategory, categoryPath: "Groceries"))
    }
    let newCharge = InsightTestSupport.expense(
      300, payee: "Fancy Restaurant", daysAgo: 2, categoryId: groceriesCategory,
      categoryPath: "Groceries")

    let insights = NewMerchantInsight.detect(
      recentCandidates: [newCharge],
      payees: InsightTestSupport.payees(from: history),
      categorySamples: InsightTestSupport.categorySamples(from: history + [newCharge]),
      context: context)
    #expect(insights.contains { $0.kind == .newMerchantAlert })
  }

  @Test
  func newMerchantQuietForKnownPayee() {
    let groceriesCategory = UUID()
    var history: [InsightTransaction] = []
    for index in 0..<12 {
      history.append(
        InsightTestSupport.expense(
          50, payee: "Groceries", daysAgo: 20 + index, categoryId: groceriesCategory,
          categoryPath: "Groceries"))
    }
    let recent = InsightTestSupport.expense(
      300, payee: "Groceries", daysAgo: 1, categoryId: groceriesCategory,
      categoryPath: "Groceries")
    let insights = NewMerchantInsight.detect(
      recentCandidates: [recent],
      payees: InsightTestSupport.payees(from: history),
      categorySamples: InsightTestSupport.categorySamples(from: history + [recent]),
      context: context)
    #expect(insights.isEmpty)
  }

  @Test
  func categoryTrendDetectsRisingCategory() throws {
    let dining = Category(name: "Dining")
    let months = ["202509", "202510", "202511", "202512", "202601", "202602", "202603", "202604"]
    let breakdown = months.enumerated().map { index, month in
      InsightTestSupport.breakdownRow(
        Decimal(100 + index * 30), categoryId: dining.id, month: month)
    }
    let insights = CategoryTrendInsight.detect(
      breakdown: breakdown, categories: Categories(from: [dining]), context: context)
    let rising = try #require(insights.first { $0.kind == .categoryTrendRising })
    #expect(rising.framing == .negative)
  }

  @Test
  func monthOverMonthSpendIncrease() throws {
    let monthly = [
      InsightTestSupport.monthly(month: "202604", income: 5000, expense: 100),
      InsightTestSupport.monthly(month: "202605", income: 5000, expense: 130),
    ]
    let insights = PeriodComparisonInsights.detect(monthly: monthly, context: context)
    let delta = try #require(insights.first { $0.kind == .monthOverMonthDelta })
    #expect(delta.framing == .negative)
  }

  @Test
  func monthOverMonthExcludesInProgressMonth() {
    // Only the current (in-progress) bucket plus one complete month — not
    // enough complete months to compare.
    let monthly = [
      InsightTestSupport.monthly(month: "202605", income: 5000, expense: 100),
      InsightTestSupport.monthly(month: "202606", income: 5000, expense: 5),
    ]
    let insights = PeriodComparisonInsights.detect(monthly: monthly, context: context)
    #expect(insights.isEmpty)
  }

  @Test
  func categoryAnomalyFlagsSpike() throws {
    let dining = Category(name: "Dining")
    let magnitudes: [Decimal] = [100, 105, 98, 102, 100, 103, 99, 400]
    let months = ["202511", "202512", "202601", "202602", "202603", "202604", "202605", "202606"]
    let breakdown = zip(months, magnitudes).map { month, magnitude in
      InsightTestSupport.breakdownRow(magnitude, categoryId: dining.id, month: month)
    }
    let insights = CategoryAnomalyInsight.detect(
      breakdown: breakdown, categories: Categories(from: [dining]), context: context)
    let anomaly = try #require(insights.first { $0.kind == .categorySpendingAnomaly })
    // The headline names the spike's month ("… in June") rather than the
    // date-rotting "this month".
    #expect(anomaly.title.contains("June"))
    #expect(!anomaly.title.contains("this month"))
  }

  @Test
  func categoryAnomalyAttachesHighlightedChart() throws {
    let dining = Category(name: "Dining")
    let magnitudes: [Decimal] = [100, 105, 98, 102, 100, 103, 99, 400]
    let months = ["202511", "202512", "202601", "202602", "202603", "202604", "202605", "202606"]
    let breakdown = zip(months, magnitudes).map { month, magnitude in
      InsightTestSupport.breakdownRow(magnitude, categoryId: dining.id, month: month)
    }
    let insights = CategoryAnomalyInsight.detect(
      breakdown: breakdown, categories: Categories(from: [dining]), context: context)
    let anomaly = try #require(insights.first { $0.kind == .categorySpendingAnomaly })
    let chart = try #require(anomaly.chart)
    #expect(chart.kind == .bar)
    #expect(chart.series.first?.points.count == 8)
    #expect(chart.highlight?.value == 400)
  }

  @Test
  func categoryAnomalySuppressesOneOffLump() {
    // A category with a thin trickle then a huge one-off (house deposit). The
    // series is long enough to clear `minimumMonths`, but its median is 0, so
    // there is no regular baseline to "overspend" against.
    let home = Category(name: "Home")
    let magnitudes: [Decimal] = [100, 0, 0, 0, 0, 500_000]
    let months = ["202501", "202502", "202503", "202504", "202505", "202506"]
    let breakdown = zip(months, magnitudes).map { month, magnitude in
      InsightTestSupport.breakdownRow(magnitude, categoryId: home.id, month: month)
    }
    let insights = CategoryAnomalyInsight.detect(
      breakdown: breakdown, categories: Categories(from: [home]), context: context)
    #expect(!insights.contains { $0.kind == .categorySpendingAnomaly })
  }

  @Test
  func categoryAnomalySuppressesAnnualRecurringPayment() {
    // The reported bug: an $80k annual superannuation payment, identical to last
    // year's, in an otherwise-empty category. Median is 0 → not an overspend.
    let superannuation = Category(name: "Superannuation")
    // The two rows gap-fill (CategorySpendSeries) into a 13-month series — 11
    // interior zeros — so it clears `minimumMonths` and reaches Gate A, where
    // the zero median suppresses it.
    let breakdown = [
      InsightTestSupport.breakdownRow(80_000, categoryId: superannuation.id, month: "202506"),
      InsightTestSupport.breakdownRow(80_000, categoryId: superannuation.id, month: "202606"),
    ]
    let insights = CategoryAnomalyInsight.detect(
      breakdown: breakdown, categories: Categories(from: [superannuation]), context: context)
    #expect(!insights.contains { $0.kind == .categorySpendingAnomaly })
  }

  @Test
  func categoryTrendAttachesChart() throws {
    let dining = Category(name: "Dining")
    let magnitudes: [Decimal] = [100, 140, 180, 220, 260, 300]
    let months = ["202601", "202602", "202603", "202604", "202605", "202606"]
    let breakdown = zip(months, magnitudes).map { month, magnitude in
      InsightTestSupport.breakdownRow(magnitude, categoryId: dining.id, month: month)
    }
    let insights = CategoryTrendInsight.detect(
      breakdown: breakdown, categories: Categories(from: [dining]), context: context)
    let trend = try #require(
      insights.first { $0.kind == .categoryTrendRising || $0.kind == .categoryTrendFalling })
    #expect(trend.chart != nil)
    #expect(trend.chart?.kind == .bar)
    #expect(trend.chart?.highlight?.value == 300)
  }
}
