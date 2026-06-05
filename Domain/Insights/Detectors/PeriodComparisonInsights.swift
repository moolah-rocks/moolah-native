import Foundation

/// Month-over-month and year-over-year deltas (design §C-11) on overall
/// spend. Operates on the pre-bucketed `MonthlyIncomeExpense` aggregates and
/// only on *complete* financial months — the in-progress current bucket is
/// excluded so a half-finished month never reads as a spending drop.
enum PeriodComparisonInsights {
  static func detect(
    monthly: [MonthlyIncomeExpense],
    context: InsightContext,
    threshold: Double = 0.15
  ) -> [Insight] {
    let currentBucket = FinancialMonth.key(
      for: context.now, monthEnd: context.financialMonthEnd)
    let complete =
      monthly
      .filter { $0.month < currentBucket }
      .sorted { $0.month < $1.month }
    guard complete.count >= 2 else { return [] }

    var insights: [Insight] = []
    if let monthOverMonth = compare(
      completeMonths: complete,
      label: "last month",
      context: context,
      threshold: threshold)
    {
      insights.append(monthOverMonth)
    }
    return insights
  }

  /// Compare the latest two complete months' total spend magnitude and emit a
  /// delta insight when the change clears `threshold`. Spend magnitude is
  /// `-(totalExpense)` because expense aggregates are stored negative.
  /// `completeMonths` (ascending, ≥2) is both the comparison source — its last
  /// two entries — and the full series the companion bar chart plots, with the
  /// latest month highlighted.
  private static func compare(
    completeMonths: [MonthlyIncomeExpense],
    label: String,
    context: InsightContext,
    threshold: Double
  ) -> Insight? {
    // Defensive: the caller already enforces ≥2 complete months; kept so this
    // private helper is sound on its own.
    guard completeMonths.count >= 2 else { return nil }
    let latest = completeMonths[completeMonths.count - 1]
    let baseline = completeMonths[completeMonths.count - 2]
    let latestSpend = magnitude(latest.totalExpense)
    let baselineSpend = magnitude(baseline.totalExpense)
    guard baselineSpend > 0 else { return nil }
    let fraction = (latestSpend - baselineSpend) / baselineSpend
    let changeMagnitude = abs(fraction)
    guard changeMagnitude >= threshold else { return nil }

    let increased = fraction > 0
    let deltaAmount = Decimal(-(latestSpend - baselineSpend))
    let monthDate = CategorySpendSeries.monthDate(latest.month) ?? latest.end
    return Insight(
      id: "\(InsightKind.monthOverMonthDelta.rawValue):\(latest.month)",
      kind: .monthOverMonthDelta,
      title: increased
        ? "Spending up \(percent(changeMagnitude)) vs \(label)"
        : "Spending down \(percent(changeMagnitude)) vs \(label)",
      date: monthDate,
      framing: increased ? .negative : .positive,
      actionability: .informational,
      surprise: min(changeMagnitude, 1),
      monetaryImpact: InstrumentAmount(
        quantity: deltaAmount, instrument: context.reportingCurrency),
      facts: [
        InsightFact("This period", context.formatted(Decimal(-latestSpend))),
        InsightFact("Comparison", context.formatted(Decimal(-baselineSpend))),
        InsightFact("Change", "\(increased ? "+" : "−")\(percent(changeMagnitude))"),
      ],
      references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
      chart: InsightChartBuilders.monthlySpend(
        monthly: completeMonths,
        reportingCurrency: context.reportingCurrency,
        highlightMonth: latest.month))
  }

  private static func magnitude(_ amount: InstrumentAmount) -> Double {
    let value = Double(truncating: amount.quantity as NSDecimalNumber)
    return value < 0 ? -value : 0
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }
}
