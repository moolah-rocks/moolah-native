import Foundation
import Testing

@testable import Moolah

@Suite("Large-transaction anomaly")
struct LargeTransactionInsightTests {
  private let context = InsightTestSupport.context()

  /// A one-off charge in a category with almost no history must not fire. The
  /// detector used to fall back to the global spend distribution for sparse
  /// categories, which flagged inherently lumpy one-offs (a car purchase, an
  /// annual super payment) and — worse — reported the *global* median as the
  /// category's "typical" spend. With too little per-category history there is
  /// no basis to call a charge unusual *for that category*, so it stays quiet.
  @Test
  func quietForSparseCategoryWithGlobalHistory() {
    let dining = UUID()
    let carPurchase = UUID()
    // A well-populated, low-value category establishes a global pool well over
    // the minimum sample count — the old fallback path's precondition.
    var samples: [InsightTransaction] = []
    let dailySpend: [Decimal] = [18, 19, 20, 21, 22, 19, 20, 21, 18]
    for (index, magnitude) in dailySpend.enumerated() {
      samples.append(
        InsightTestSupport.expense(
          magnitude, payee: "Cafe", daysAgo: index * 7 + 30, categoryId: dining,
          categoryPath: "Dining"))
    }
    // The car-purchase category has only a prior $1,000 deposit plus the huge
    // one-off — two samples, below the per-category minimum.
    let priorDeposit = InsightTestSupport.expense(
      1_000, payee: "EV Dealer Group", daysAgo: 120, categoryId: carPurchase,
      categoryPath: "Extraordinary:Car Purchase")
    let bigPurchase = InsightTestSupport.expense(
      32_596, payee: "EV Dealer Group", daysAgo: 2, categoryId: carPurchase,
      categoryPath: "Extraordinary:Car Purchase")

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [bigPurchase],
      payees: InsightTestSupport.payees(from: samples + [priorDeposit, bigPurchase]),
      categorySamples: InsightTestSupport.categorySamples(
        from: samples + [priorDeposit, bigPurchase]),
      context: context)

    #expect(!insights.contains { $0.kind == .largeTransactionAnomaly })
  }

  /// When the insight does fire, the "Typical for category" fact is that
  /// category's own median — never a global figure borrowed from unrelated
  /// spending. A second, high-value category skews the global median away from
  /// the outlier's category so a global leak would be visible.
  @Test
  func typicalReflectsTheOutliersOwnCategory() throws {
    let dining = UUID()
    let rent = UUID()
    var samples: [InsightTransaction] = []
    // Dining: tight cluster around 20 — median 20.
    let diningSpend: [Decimal] = [18, 19, 20, 21, 22, 19, 20, 21, 18]
    for (index, magnitude) in diningSpend.enumerated() {
      samples.append(
        InsightTestSupport.expense(
          magnitude, payee: "Cafe", daysAgo: index * 7 + 30, categoryId: dining,
          categoryPath: "Dining"))
    }
    // Rent: a separate well-populated category at a far higher level, which
    // would drag any global median upward.
    for index in 0..<9 {
      samples.append(
        InsightTestSupport.expense(
          2_000, payee: "Landlord", daysAgo: index * 30 + 30, categoryId: rent,
          categoryPath: "Rent"))
    }
    let outlier = InsightTestSupport.expense(
      200, payee: "Steakhouse", daysAgo: 2, categoryId: dining, categoryPath: "Dining")

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [outlier],
      payees: InsightTestSupport.payees(from: samples + [outlier]),
      categorySamples: InsightTestSupport.categorySamples(from: samples + [outlier]),
      context: context)

    let anomaly = try #require(insights.first { $0.kind == .largeTransactionAnomaly })
    #expect(anomaly.presentationKey == anomaly.id)
    let typical = try #require(anomaly.facts.first { $0.label == "Typical for category" })
    // Dining median is 20 (expenses are negative), not anything near the
    // 2,000-skewed global figure.
    #expect(typical.value == context.formatted(Decimal(-20)))
  }

  @Test
  func quietForEstablishedSameMerchantAmount() {
    let fixture = donationFixture(latestAmount: 1_500)

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [fixture.candidate],
      payees: InsightTestSupport.payees(from: fixture.history + [fixture.candidate]),
      categorySamples: InsightTestSupport.categorySamples(
        from: fixture.history + [fixture.candidate]),
      context: context)

    #expect(!insights.contains { $0.kind == .largeTransactionAnomaly })
  }

  @Test
  func flagsMaterialIncreaseFromEstablishedMerchant() {
    let fixture = donationFixture(latestAmount: 2_000)

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [fixture.candidate],
      payees: InsightTestSupport.payees(from: fixture.history + [fixture.candidate]),
      categorySamples: InsightTestSupport.categorySamples(
        from: fixture.history + [fixture.candidate]),
      context: context)

    #expect(insights.contains { $0.kind == .largeTransactionAnomaly })
  }

  @Test
  func heterogeneousMerchantHistoryDoesNotEstablishAmount() {
    let fixture = donationFixture(
      latestAmount: 1_500,
      merchantHistoryAmounts: [100, 1_500, 2_900])

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [fixture.candidate],
      payees: InsightTestSupport.payees(from: fixture.history + [fixture.candidate]),
      categorySamples: InsightTestSupport.categorySamples(
        from: fixture.history + [fixture.candidate]),
      context: context)

    #expect(insights.contains { $0.kind == .largeTransactionAnomaly })
  }

  @Test
  func quietWhenMatchingMerchantHistoryIsUnavailable() {
    let fixture = donationFixture(
      latestAmount: 1_500,
      merchantHistoryAmounts: [100, 1_500, 2_900])
    let availablePayees = InsightTestSupport.payees(
      from: fixture.history + [fixture.candidate])
    let payees = availablePayees.map { payee in
      PayeeSummary(
        normalizedPayee: payee.normalizedPayee,
        displayPayee: payee.displayPayee,
        isExpense: payee.isExpense,
        occurrenceCount: payee.occurrenceCount,
        firstSeen: payee.firstSeen,
        lastSeen: payee.lastSeen,
        windowedTotal: payee.windowedTotal,
        occurrences: payee.occurrences,
        hasUnavailableData: payee.normalizedPayee == fixture.candidate.normalizedPayee)
    }

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [fixture.candidate],
      payees: payees,
      categorySamples: InsightTestSupport.categorySamples(
        from: fixture.history + [fixture.candidate]),
      context: context)

    #expect(!insights.contains { $0.kind == .largeTransactionAnomaly })
  }

  @Test
  func unrelatedUnavailableMerchantDoesNotSuppressAnomaly() {
    let fixture = donationFixture(
      latestAmount: 1_500,
      merchantHistoryAmounts: [100, 1_500, 2_900])
    let unrelatedHistory = (1...3).map { occurrence in
      InsightTestSupport.expense(
        50,
        payee: "Other Merchant",
        daysAgo: occurrence * 20)
    }
    let unavailablePayee = InsightTestSupport.payees(from: unrelatedHistory).map { payee in
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
    let payees =
      InsightTestSupport.payees(from: fixture.history + [fixture.candidate])
      + unavailablePayee

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [fixture.candidate],
      payees: payees,
      categorySamples: InsightTestSupport.categorySamples(
        from: fixture.history + [fixture.candidate]),
      context: context)

    #expect(insights.contains { $0.kind == .largeTransactionAnomaly })
  }

  @Test
  func quietForThreeNearMerchantAmounts() {
    let fixture = donationFixture(
      latestAmount: 1_500,
      merchantHistoryAmounts: [100, 1_400, 1_500, 1_600, 2_900])

    let insights = LargeTransactionInsight.detect(
      recentCandidates: [fixture.candidate],
      payees: InsightTestSupport.payees(from: fixture.history + [fixture.candidate]),
      categorySamples: InsightTestSupport.categorySamples(
        from: fixture.history + [fixture.candidate]),
      context: context)

    #expect(!insights.contains { $0.kind == .largeTransactionAnomaly })
  }
}

extension LargeTransactionInsightTests {
  private func donationFixture(
    latestAmount: Decimal,
    merchantHistoryAmounts: [Decimal] = Array(repeating: 1_500, count: 11)
  ) -> (candidate: InsightTransaction, history: [InsightTransaction]) {
    let donations = UUID()
    let merchantHistory = merchantHistoryAmounts.enumerated().map { index, amount in
      InsightTestSupport.expense(
        amount,
        payee: "Family Radio",
        daysAgo: (index + 1) * 30 + 2,
        categoryId: donations,
        categoryPath: "Donations")
    }
    let smallerDonations = (1...40).map { occurrence in
      InsightTestSupport.expense(
        Decimal(25 + occurrence % 5),
        payee: "Local Charity",
        daysAgo: occurrence * 8,
        categoryId: donations,
        categoryPath: "Donations")
    }
    let candidate = InsightTestSupport.expense(
      latestAmount,
      payee: "Family Radio",
      daysAgo: 2,
      categoryId: donations,
      categoryPath: "Donations")
    return (candidate, merchantHistory + smallerDonations)
  }
}
