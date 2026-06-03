import Foundation

/// Large-transaction anomaly (design §B-7): a recent expense whose magnitude
/// is a robust-z (MAD-z) outlier within its own category. MAD-z is used
/// instead of a raw z-score because spending distributions are heavy-tailed
/// and a single prior outlier would inflate a classic standard deviation.
///
/// Sparse categories (too few samples for a stable per-category scale) fall
/// back to the global spend distribution — a pragmatic stand-in for the
/// design's "Bayesian shrinkage toward a global prior".
///
/// The per-category baseline (`categorySamples`) only covers categorised
/// expense legs — the SQL that builds it filters `category_id IS NOT NULL`,
/// so uncategorised spend is excluded from the baseline. This is an accepted
/// approximation of the old full-history baseline that scanned every leg.
enum LargeTransactionInsight {
  static func detect(
    recentCandidates: [InsightTransaction],
    categorySamples: [CategorySpendSamples],
    categories: Categories,
    context: InsightContext,
    windowDays: Int = 30,
    threshold: Double = 3.5,
    minimumCategorySamples: Int = 6
  ) -> [Insight] {
    let globalMagnitudes = categorySamples.flatMap(\.magnitudes).map(toDouble)
    guard globalMagnitudes.count >= minimumCategorySamples else { return [] }

    let samplesByCategory = Dictionary(
      categorySamples.map { ($0.categoryId, $0.magnitudes.map(toDouble)) },
      uniquingKeysWith: { first, _ in first })

    var insights: [Insight] = []
    for transaction in recentCandidates.filter(\.isExpense) {
      let age = context.daysSince(transaction.date)
      guard age >= 0, age <= windowDays else { continue }

      let categoryPeers = samplesByCategory[transaction.categoryId] ?? []
      let population =
        categoryPeers.count >= minimumCategorySamples
        ? categoryPeers
        : globalMagnitudes
      let value = spendMagnitude(transaction)
      let zScore = DescriptiveStatistics.robustZScore(of: value, in: population)
      guard zScore >= threshold, value > 0 else { continue }

      let typical = DescriptiveStatistics.median(population)
      let categoryName = transaction.categoryPath ?? "Uncategorized"
      insights.append(
        Insight(
          id: "\(InsightKind.largeTransactionAnomaly.rawValue):\(transaction.id.uuidString)",
          kind: .largeTransactionAnomaly,
          title: "Unusually large \(categoryName) charge",
          detail:
            "\(payeeName(transaction)) for \(context.formatted(transaction.amount)) is "
            + "well above your typical \(categoryName) spend of "
            + "\(context.formatted(Decimal(-typical))).",
          date: transaction.date,
          framing: .negative,
          actionability: .review,
          surprise: NormalDistribution.surprise(fromZScore: zScore),
          monetaryImpact: transaction.amountInReportingCurrency(context),
          facts: [
            InsightFact("Merchant", payeeName(transaction)),
            InsightFact("Amount", context.formatted(transaction.amount)),
            InsightFact("Category", categoryName),
            InsightFact("Typical for category", context.formatted(Decimal(-typical))),
          ],
          references: InsightReferences(
            accountIds: transaction.accountId.map { [$0] } ?? [],
            categoryIds: transaction.categoryId.map { [$0] } ?? [],
            transactionIds: [transaction.id])))
    }
    return insights
  }

  private static func spendMagnitude(_ transaction: InsightTransaction) -> Double {
    Double(truncating: transaction.spendMagnitude as NSDecimalNumber)
  }

  private static func toDouble(_ value: Decimal) -> Double {
    Double(truncating: value as NSDecimalNumber)
  }

  private static func payeeName(_ transaction: InsightTransaction) -> String {
    transaction.rawPayee ?? "A transaction"
  }
}

extension InsightTransaction {
  /// This record's signed amount as an `InstrumentAmount` in the reporting
  /// currency — a convenience for detectors building `monetaryImpact`.
  func amountInReportingCurrency(_ context: InsightContext) -> InstrumentAmount {
    InstrumentAmount(quantity: amount, instrument: context.reportingCurrency)
  }
}
