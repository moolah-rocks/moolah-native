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
    var transactions: [InsightTransaction] = []
    let normals: [Decimal] = [18, 19, 20, 21, 22, 19, 20, 21, 18]
    for (index, magnitude) in normals.enumerated() {
      transactions.append(
        InsightTestSupport.expense(
          magnitude, payee: "Cafe", daysAgo: index * 4 + 1, categoryId: dining,
          categoryPath: "Dining"))
    }
    transactions.append(
      InsightTestSupport.expense(
        200, payee: "Steakhouse", daysAgo: 2, categoryId: dining, categoryPath: "Dining"))

    let insights = LargeTransactionInsight.detect(
      transactions: transactions, categories: emptyCategories, context: context)
    let anomaly = try #require(insights.first { $0.kind == .largeTransactionAnomaly })
    #expect(anomaly.references.transactionIds.count == 1)
    #expect(anomaly.surprise > 0.9)
  }

  @Test
  func newMerchantAlertFiresForLargeFirstCharge() {
    var transactions: [InsightTransaction] = []
    for index in 0..<12 {
      transactions.append(
        InsightTestSupport.expense(Decimal(20 + index), payee: "Groceries", daysAgo: 20 + index))
    }
    transactions.append(
      InsightTestSupport.expense(300, payee: "Fancy Restaurant", daysAgo: 2))

    let insights = NewMerchantInsight.detect(transactions: transactions, context: context)
    #expect(insights.contains { $0.kind == .newMerchantAlert })
  }

  @Test
  func newMerchantQuietForKnownPayee() {
    var transactions: [InsightTransaction] = []
    for index in 0..<12 {
      transactions.append(
        InsightTestSupport.expense(50, payee: "Groceries", daysAgo: 20 + index))
    }
    transactions.append(InsightTestSupport.expense(300, payee: "Groceries", daysAgo: 1))
    let insights = NewMerchantInsight.detect(transactions: transactions, context: context)
    #expect(insights.isEmpty)
  }

  @Test
  func categoryTrendDetectsRisingCategory() throws {
    let dining = Category(name: "Dining")
    let months = ["202509", "202510", "202511", "202512", "202601", "202602", "202603", "202604"]
    let breakdown = months.enumerated().map { index, month in
      InsightTestSupport.breakdownRow(Decimal(100 + index * 30), categoryId: dining.id, month: month)
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
    #expect(insights.contains { $0.kind == .categorySpendingAnomaly })
  }
}
