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

    let bounds = Bounds(zScore: threshold, overspendFraction: minimumOverspendFraction)
    var insights: [Insight] = []
    for (categoryId, points) in series where points.count >= minimumMonths {
      guard
        let insight = evaluate(
          categoryId: categoryId,
          points: points,
          categories: categories,
          context: context,
          bounds: bounds)
      else { continue }
      insights.append(insight)
    }
    return insights
  }

  /// The two gate values an anomaly must clear, bundled to keep `evaluate`
  /// within the parameter-count budget.
  private struct Bounds {
    let zScore: Double
    let overspendFraction: Double
  }

  private static func evaluate(
    categoryId: UUID,
    points: [MonthlySpendPoint],
    categories: Categories,
    context: InsightContext,
    bounds: Bounds
  ) -> Insight? {
    let magnitudes = points.map(\.magnitude)
    // Gate A — regularity. An overspend is only meaningful against an established
    // baseline. A category with spend in <= half its months (median 0) is a lump
    // (one-off purchase) or a rare periodic payment, not an overspend.
    guard DescriptiveStatistics.median(magnitudes) > 0 else { return nil }
    let decomposition = SeasonalDecomposition.decompose(magnitudes, period: 12)
    let remainder = decomposition.remainder
    guard let latest = points.last, remainder.count == points.count else { return nil }

    let latestRemainder = remainder[remainder.count - 1]
    let priorRemainders = Array(remainder.dropLast())
    let zScore = DescriptiveStatistics.robustZScore(of: latestRemainder, in: priorRemainders)
    guard zScore >= bounds.zScore, latestRemainder > 0 else { return nil }

    let expected =
      decomposition.trend[remainder.count - 1]
      + decomposition.seasonal[remainder.count - 1]
    guard expected > 0 else { return nil }
    let overspendFraction = latestRemainder / expected
    guard overspendFraction >= bounds.overspendFraction else { return nil }

    let resolved =
      categoryId == CategorySpendSeries.uncategorizedKey
      ? nil : categories.by(id: categoryId)
    let categoryName = resolved.map { categories.path(for: $0) } ?? "Uncategorized"
    // The anomaly fires on the latest available financial month, which may be
    // the in-progress current month; naming it (e.g. "in June") avoids the
    // date-rot of "this month". `latest.date` is the first-of-month UTC date
    // from `CategorySpendSeries`, so format it against the same UTC calendar.
    let monthName = latest.date.formatted(monthStyle(context))

    return Insight(
      id:
        "\(InsightKind.categorySpendingAnomaly.rawValue):\(categoryId.uuidString):\(latest.month)",
      kind: .categorySpendingAnomaly,
      title: "\(categoryName) up \(percent(overspendFraction)) in \(monthName)",
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
      ],
      references: InsightReferences(
        categoryIds: resolved.map { [$0.id] } ?? [],
        instrumentIds: [context.reportingCurrency.id]),
      chart: InsightChartBuilders.categorySpend(
        points: points,
        reportingCurrency: context.reportingCurrency,
        highlightMonth: latest.month))
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }

  /// Wide month name pinned to the context calendar's time zone so a
  /// first-of-month UTC date doesn't roll back a month when rendered.
  private static func monthStyle(_ context: InsightContext) -> Date.FormatStyle {
    Date.FormatStyle(calendar: context.calendar, timeZone: context.calendar.timeZone)
      .month(.wide)
  }
}
