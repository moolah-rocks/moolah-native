import Foundation

/// Category spending anomaly (design §B-6): the latest month's spend for a
/// category is a robust-z outlier on the remainder of a seasonal-trend
/// decomposition ("dining up 40% this month"). Decomposing first means a
/// recurring seasonal bump (December gifts, summer travel) is absorbed into
/// the seasonal term instead of mis-firing as an anomaly.
///
/// Only *over*-spend is flagged (positive remainder). The most recent
/// financial month may be incomplete, which can only depress spend, so
/// restricting to over-spend sidesteps partial-month false positives;
/// under-spend reaches the user through the positive-framed budget and MoM
/// detectors instead.
enum CategoryAnomalyInsight {
  static func detect(
    breakdown: [ExpenseBreakdown],
    categories: Categories,
    context: InsightContext,
    minimumMonths: Int = 6,
    threshold: Double = 3,
    minimumOverspendFraction: Double = 0.25
  ) -> [Insight] {
    let series = CategorySpendSeries.build(
      from: breakdown, reportingCurrency: context.reportingCurrency)

    var insights: [Insight] = []
    for (categoryId, points) in series where points.count >= minimumMonths {
      guard let insight = evaluate(
        categoryId: categoryId, points: points, categories: categories,
        context: context, threshold: threshold,
        minimumOverspendFraction: minimumOverspendFraction)
      else { continue }
      insights.append(insight)
    }
    return insights
  }

  private static func evaluate(
    categoryId: UUID,
    points: [MonthlySpendPoint],
    categories: Categories,
    context: InsightContext,
    threshold: Double,
    minimumOverspendFraction: Double
  ) -> Insight? {
    let magnitudes = points.map(\.magnitude)
    let decomposition = SeasonalDecomposition.decompose(magnitudes, period: 12)
    let remainder = decomposition.remainder
    guard let latest = points.last, remainder.count == points.count else { return nil }

    let latestRemainder = remainder[remainder.count - 1]
    let priorRemainders = Array(remainder.dropLast())
    let zScore = DescriptiveStatistics.robustZScore(of: latestRemainder, in: priorRemainders)
    guard zScore >= threshold, latestRemainder > 0 else { return nil }

    let expected = decomposition.trend[remainder.count - 1]
      + decomposition.seasonal[remainder.count - 1]
    guard expected > 0 else { return nil }
    let overspendFraction = latestRemainder / expected
    guard overspendFraction >= minimumOverspendFraction else { return nil }

    let resolved = categoryId == CategorySpendSeries.uncategorizedKey
      ? nil : categories.by(id: categoryId)
    let categoryName = resolved.map { categories.path(for: $0) } ?? "Uncategorized"

    return Insight(
      id: "\(InsightKind.categorySpendingAnomaly.rawValue):\(categoryId.uuidString):\(latest.month)",
      kind: .categorySpendingAnomaly,
      title: "\(categoryName) up this month",
      detail:
        "\(categoryName) spend of \(context.formatted(Decimal(-latest.magnitude))) is "
        + "\(percent(overspendFraction)) above the \(context.formatted(Decimal(-expected))) "
        + "you'd typically expect this month.",
      date: latest.date,
      framing: .negative,
      actionability: .review,
      surprise: NormalDistribution.surprise(fromZScore: zScore),
      monetaryImpact: InstrumentAmount(
        quantity: Decimal(-latestRemainder), instrument: context.reportingCurrency),
      facts: [
        InsightFact("Category", categoryName),
        InsightFact("This month", context.formatted(Decimal(-latest.magnitude))),
        InsightFact("Expected", context.formatted(Decimal(-expected))),
        InsightFact("Over by", percent(overspendFraction)),
        InsightFact("Robust z-score", zScore.formatted(.number.precision(.fractionLength(1)))),
      ],
      references: InsightReferences(
        categoryIds: resolved.map { [$0.id] } ?? [],
        instrumentIds: [context.reportingCurrency.id]))
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }
}
