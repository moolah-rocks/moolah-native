import Foundation
import Testing

@testable import Moolah

@Suite("Large-transaction anomaly")
struct LargeTransactionInsightTests {
  private let context = InsightTestSupport.context()
  private let emptyCategories = Categories(from: [])

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
      categorySamples: InsightTestSupport.categorySamples(
        from: samples + [priorDeposit, bigPurchase]),
      categories: emptyCategories, context: context)

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
      categorySamples: InsightTestSupport.categorySamples(from: samples + [outlier]),
      categories: emptyCategories, context: context)

    let anomaly = try #require(insights.first { $0.kind == .largeTransactionAnomaly })
    let typical = try #require(anomaly.facts.first { $0.label == "Typical for category" })
    // Dining median is 20 (expenses are negative), not anything near the
    // 2,000-skewed global figure.
    #expect(typical.value == context.formatted(Decimal(-20)))
  }
}
