import Foundation
import Testing

@testable import Moolah

@Suite("New merchant insights")
struct NewMerchantInsightTests {
  private let context = InsightTestSupport.context()

  @Test
  func alertFiresForLargeFirstChargeFromRepeatedMerchant() throws {
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
    let repeatCharge = InsightTestSupport.expense(
      40, payee: "Fancy Restaurant", daysAgo: 1, categoryId: groceriesCategory,
      categoryPath: "Groceries")

    let insights = NewMerchantInsight.detect(
      recentCandidates: [newCharge, repeatCharge],
      payees: InsightTestSupport.payees(from: history + [newCharge, repeatCharge]),
      categorySamples: InsightTestSupport.categorySamples(
        from: history + [newCharge, repeatCharge]),
      context: context)
    let insight = try #require(insights.first { $0.kind == .newMerchantAlert })
    let filter = try #require(insight.references.transactionFilter)
    #expect(filter.categoryIds == [groceriesCategory])
    #expect(filter.transactionTypes == [.expense])
    #expect(filter.payee == "Fancy Restaurant")
    #expect(filter.dateRange?.contains(newCharge.date) == true)
  }

  @Test
  func alertIgnoresOneOffCharge() {
    let category = UUID()
    let history = (0..<12).map { index in
      InsightTestSupport.expense(
        Decimal(20 + index),
        payee: "Groceries",
        daysAgo: 20 + index,
        categoryId: category)
    }
    let oneOffCharge = InsightTestSupport.expense(
      300, payee: "One-off Merchant", daysAgo: 2, categoryId: category)

    let insights = NewMerchantInsight.detect(
      recentCandidates: [oneOffCharge],
      payees: InsightTestSupport.payees(from: history + [oneOffCharge]),
      categorySamples: InsightTestSupport.categorySamples(from: history + [oneOffCharge]),
      context: context)

    #expect(insights.isEmpty)
  }

  @Test
  func alertIgnoresOneOffChargeSplitAcrossCategories() {
    let category = UUID()
    let otherCategory = UUID()
    let history = (0..<12).map { index in
      InsightTestSupport.expense(
        Decimal(20 + index),
        payee: "Groceries",
        daysAgo: 20 + index,
        categoryId: category)
    }
    let transactionId = UUID()
    let splitCharge = [
      InsightTestSupport.expense(
        300, payee: "Split Merchant", daysAgo: 2, categoryId: category, id: transactionId),
      InsightTestSupport.expense(
        40, payee: "Split Merchant", daysAgo: 2, categoryId: otherCategory, id: transactionId),
    ]

    let insights = NewMerchantInsight.detect(
      recentCandidates: splitCharge,
      payees: InsightTestSupport.payees(from: history + splitCharge),
      categorySamples: InsightTestSupport.categorySamples(from: history + splitCharge),
      context: context)

    #expect(insights.isEmpty)
  }

  @Test
  func alertSurvivesUnrelatedUnavailablePayee() {
    let category = UUID()
    let history = (0..<12).map { index in
      InsightTestSupport.expense(
        Decimal(20 + index),
        payee: "Groceries",
        daysAgo: 20 + index,
        categoryId: category)
    }
    let newCharge = InsightTestSupport.expense(
      300, payee: "Fancy Restaurant", daysAgo: 2, categoryId: category)
    let repeatCharge = InsightTestSupport.expense(
      40, payee: "Fancy Restaurant", daysAgo: 1, categoryId: category)
    let unavailablePayees = InsightTestSupport.payees(from: history).map { payee in
      PayeeSummary(
        normalizedPayee: payee.normalizedPayee,
        displayPayee: payee.displayPayee,
        isExpense: payee.isExpense,
        occurrenceCount: payee.occurrenceCount,
        firstSeen: payee.firstSeen,
        lastSeen: payee.lastSeen,
        windowedTotal: payee.windowedTotal,
        occurrences: payee.occurrences,
        hasUnavailableData: true)
    }
    let newMerchantPayees = InsightTestSupport.payees(from: [newCharge, repeatCharge])
    let input = InsightInput(
      context: context,
      dataAvailability: .init(payees: false),
      recentCandidates: [newCharge, repeatCharge],
      payees: unavailablePayees + newMerchantPayees,
      categorySamples: InsightTestSupport.categorySamples(
        from: history + [newCharge, repeatCharge]))

    #expect(InsightEngine().detectAll(input).contains { $0.kind == .newMerchantAlert })
  }

  @Test
  func alertIsQuietForKnownPayee() {
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
    let repeatCharge = InsightTestSupport.expense(
      40, payee: "Groceries", daysAgo: 0, categoryId: groceriesCategory,
      categoryPath: "Groceries")
    let insights = NewMerchantInsight.detect(
      recentCandidates: [recent, repeatCharge],
      payees: InsightTestSupport.payees(from: history + [recent, repeatCharge]),
      categorySamples: InsightTestSupport.categorySamples(from: history + [recent, repeatCharge]),
      context: context)
    #expect(insights.isEmpty)
  }
}
