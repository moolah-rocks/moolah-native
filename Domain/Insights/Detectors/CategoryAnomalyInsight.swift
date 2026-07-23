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
    minimumOverspendFraction: Double = 0.25,
    recurrenceLags: [Int] = [12, 6, 3],
    recurrenceTolerance: Double = 0.6
  ) -> [Insight] {
    let series = CategorySpendSeries.build(
      from: breakdown, reportingCurrency: context.reportingCurrency)

    let gates = Gates(
      zScore: threshold,
      overspendFraction: minimumOverspendFraction,
      recurrenceLags: recurrenceLags,
      recurrenceTolerance: recurrenceTolerance)
    var insights: [Insight] = []
    for (categoryId, points) in series where points.count >= minimumMonths {
      guard
        let insight = evaluate(
          categoryId: categoryId,
          points: points,
          categories: categories,
          context: context,
          gates: gates)
      else { continue }
      insights.append(insight)
    }
    return insights
  }

  /// The gate values an anomaly must clear, bundled to keep `evaluate` within
  /// the parameter-count budget.
  private struct Gates {
    let zScore: Double
    let overspendFraction: Double
    /// Cadence lags (months) checked for a recurring spike: annual, semi-annual,
    /// quarterly.
    let recurrenceLags: [Int]
    /// A prior spike at a cadence lag of at least this fraction of the latest
    /// spike's magnitude counts as "recurring".
    let recurrenceTolerance: Double
  }

  private struct FactValues {
    let categoryName: String
    let period: String
    let latest: MonthlySpendPoint
    let seriesMonths: Int
    let expected: Double
    let overspendFraction: Double
  }

  private struct Metrics {
    let latestRemainder: Double
    let expected: Double
    let overspendFraction: Double
    let zScore: Double
  }

  private static func evaluate(
    categoryId: UUID,
    points: [MonthlySpendPoint],
    categories: Categories,
    context: InsightContext,
    gates: Gates
  ) -> Insight? {
    let magnitudes = points.map(\.magnitude)
    // Gate A — regularity. An overspend is only meaningful against an established
    // baseline. A category whose median monthly spend is zero — a one-off lump
    // (house purchase) or a rare periodic payment (annual bill) — has no "usual"
    // to overspend against, so it is never flagged.
    guard DescriptiveStatistics.median(magnitudes) > 0 else { return nil }
    guard let latest = points.last,
      let metrics = metrics(magnitudes: magnitudes, pointCount: points.count, gates: gates)
    else { return nil }

    let resolved = resolvedCategory(categoryId, categories: categories)
    let categoryName = resolved.map { categories.path(for: $0) } ?? "Uncategorized"
    guard let period = context.formattedFinancialMonth(latest.month) else { return nil }
    // The anomaly fires on the latest available financial month, which may be
    // the in-progress current month; naming it (e.g. "in June") avoids the
    // date-rot of "this month". `latest.date` is the first-of-month UTC date
    // from `CategorySpendSeries`, so format it against the same UTC calendar.
    return Insight(
      id:
        "\(InsightKind.categorySpendingAnomaly.rawValue):\(categoryId.uuidString):\(latest.month)",
      presentationKey:
        "\(InsightKind.categorySpendingAnomaly.rawValue):\(categoryId.uuidString)",
      kind: .categorySpendingAnomaly,
      title:
        "\(categoryName) up \(percent(metrics.overspendFraction)) in \(period)",
      date: latest.date,
      framing: .negative,
      actionability: .review,
      surprise: NormalDistribution.surprise(fromZScore: metrics.zScore),
      monetaryImpact: InstrumentAmount(
        quantity: Decimal(-metrics.latestRemainder), instrument: context.reportingCurrency),
      facts: facts(
        FactValues(
          categoryName: categoryName,
          period: period,
          latest: latest,
          seriesMonths: points.count,
          expected: metrics.expected,
          overspendFraction: metrics.overspendFraction),
        context: context),
      references: references(for: resolved, context: context),
      chart: InsightChartBuilders.categorySpend(
        points: points,
        reportingCurrency: context.reportingCurrency,
        highlightMonth: latest.month))
  }

  private static func metrics(
    magnitudes: [Double],
    pointCount: Int,
    gates: Gates
  ) -> Metrics? {
    let decomposition = SeasonalDecomposition.decompose(magnitudes, period: 12)
    let remainder = decomposition.remainder
    guard remainder.count == pointCount else { return nil }
    let latestRemainder = remainder[remainder.count - 1]
    let zScore = DescriptiveStatistics.robustZScore(
      of: latestRemainder, in: Array(remainder.dropLast()))
    guard zScore >= gates.zScore, latestRemainder > 0 else { return nil }
    let expected =
      decomposition.trend[remainder.count - 1]
      + decomposition.seasonal[remainder.count - 1]
    guard expected > 0 else { return nil }
    let overspendFraction = latestRemainder / expected
    guard overspendFraction >= gates.overspendFraction,
      !isRecurringSpike(
        magnitudes: magnitudes,
        lags: gates.recurrenceLags,
        tolerance: gates.recurrenceTolerance)
    else { return nil }
    return Metrics(
      latestRemainder: latestRemainder,
      expected: expected,
      overspendFraction: overspendFraction,
      zScore: zScore)
  }

  private static func facts(
    _ values: FactValues,
    context: InsightContext
  ) -> [InsightFact] {
    [
      InsightFact("Category", values.categoryName),
      InsightFact("Month", values.period),
      InsightFact("Spent", context.formatted(Decimal(-values.latest.magnitude))),
      InsightFact("Expected", context.formatted(Decimal(-values.expected))),
      InsightFact("Series months", "\(max(values.seriesMonths, 1))"),
      InsightFact("Over by", percent(values.overspendFraction)),
    ]
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }

  private static func resolvedCategory(_ id: UUID, categories: Categories) -> Category? {
    guard id != CategorySpendSeries.uncategorizedKey else { return nil }
    return categories.by(id: id)
  }

  private static func references(
    for category: Category?, context: InsightContext
  ) -> InsightReferences {
    InsightReferences(
      categoryIds: category.map { [$0.id] } ?? [],
      instrumentIds: [context.reportingCurrency.id])
  }

  /// True when the latest month's spike has a comparable spike (>= `tolerance`
  /// of its magnitude) at one of the cadence `lags`, allowing +/-1 month of
  /// date drift across month buckets.
  private static func isRecurringSpike(
    magnitudes: [Double], lags: [Int], tolerance: Double
  ) -> Bool {
    guard let latest = magnitudes.last, latest > 0 else { return false }
    let latestIndex = magnitudes.count - 1
    let minimumMagnitude = latest * tolerance
    for lag in lags {
      for offset in -1...1 {
        let index = latestIndex - lag + offset
        guard index >= 0, index < latestIndex else { continue }
        if magnitudes[index] >= minimumMagnitude { return true }
      }
    }
    return false
  }
}
