import Foundation

/// Monotonic category trend (design §C-10): a category whose monthly spend
/// is rising (or falling) over the trailing window, established by the
/// Mann-Kendall test with a Sen's-slope magnitude.
///
/// Benjamini-Hochberg FDR control is applied across the whole family of
/// per-category tests before anything is surfaced — without it, testing
/// dozens of categories manufactures spurious "trends" and spams the user.
/// A falling-spend trend is framed positively; a rising one negatively.
enum CategoryTrendInsight {
  static func detect(
    breakdown: [ExpenseBreakdown],
    categories: Categories,
    context: InsightContext,
    windowMonths: Int = 12,
    minimumMonths: Int = 4,
    fdr: Double = 0.1,
    minimumRelativeChange: Double = 0.2
  ) -> [Insight] {
    let series = CategorySpendSeries.build(
      from: breakdown, reportingCurrency: context.reportingCurrency)

    var results: [UUID: (result: MannKendallResult, points: [MonthlySpendPoint])] = [:]
    var hypotheses: [PValue<UUID>] = []
    for (categoryId, allPoints) in series {
      let points = Array(allPoints.suffix(windowMonths))
      guard points.count >= minimumMonths else { continue }
      let magnitudes = points.map(\.magnitude)
      guard let result = MannKendall.test(magnitudes) else { continue }

      let mean = DescriptiveStatistics.mean(magnitudes)
      guard mean > 0 else { continue }
      let cumulativeChange = abs(result.sensSlope) * Double(points.count - 1)
      guard cumulativeChange >= minimumRelativeChange * mean else { continue }

      results[categoryId] = (result, points)
      hypotheses.append(PValue(tag: categoryId, pValue: result.pValue))
    }

    let significant = BenjaminiHochberg.significant(hypotheses, fdr: fdr)
    return significant.compactMap { hypothesis in
      guard let entry = results[hypothesis.tag] else { return nil }
      return makeInsight(
        categoryId: hypothesis.tag, result: entry.result, points: entry.points,
        categories: categories, context: context)
    }
  }

  private static func makeInsight(
    categoryId: UUID,
    result: MannKendallResult,
    points: [MonthlySpendPoint],
    categories: Categories,
    context: InsightContext
  ) -> Insight? {
    guard result.statistic != 0, let latest = points.last else { return nil }
    let months = points.count
    let totalChange = result.sensSlope * Double(months - 1)
    let resolved = categoryId == CategorySpendSeries.uncategorizedKey
      ? nil : categories.by(id: categoryId)
    let categoryName = resolved.map { categories.path(for: $0) } ?? "Uncategorized"
    let rising = result.isIncreasing
    let kind: InsightKind = rising ? .categoryTrendRising : .categoryTrendFalling
    let perMonth = context.formatted(Decimal(-abs(result.sensSlope)))
    let direction = rising ? "rising" : "easing"

    return Insight(
      id: "\(kind.rawValue):\(categoryId.uuidString)",
      kind: kind,
      title: "\(categoryName) spend \(direction)",
      detail:
        "\(categoryName) has been \(direction) for about \(months) months — "
        + "roughly \(perMonth)/month, \(rising ? "up" : "down") "
        + "\(context.formatted(Decimal(-abs(totalChange)))) over the period.",
      date: latest.date,
      framing: rising ? .negative : .positive,
      actionability: .review,
      surprise: NormalDistribution.surprise(fromZScore: result.zScore),
      monetaryImpact: InstrumentAmount(
        quantity: Decimal(rising ? -abs(totalChange) : abs(totalChange)),
        instrument: context.reportingCurrency),
      facts: [
        InsightFact("Category", categoryName),
        InsightFact("Direction", rising ? "Rising" : "Falling"),
        InsightFact("Per month", perMonth),
        InsightFact("Over \(months) months", context.formatted(Decimal(-abs(totalChange)))),
        InsightFact("Trend p-value", result.pValue.formatted(.number.precision(.fractionLength(3)))),
      ],
      references: InsightReferences(
        categoryIds: resolved.map { [$0.id] } ?? [],
        instrumentIds: [context.reportingCurrency.id]))
  }
}
