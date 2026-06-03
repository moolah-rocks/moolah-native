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
      latest: complete[complete.count - 1],
      baseline: complete[complete.count - 2],
      label: "last month",
      context: context,
      threshold: threshold)
    {
      insights.append(monthOverMonth)
    }
    return insights
  }

  /// Compare two months' total spend magnitude and emit a delta insight when
  /// the change clears `threshold`. Spend magnitude is `-(totalExpense)`
  /// because expense aggregates are stored negative.
  private static func compare(
    latest: MonthlyIncomeExpense,
    baseline: MonthlyIncomeExpense,
    label: String,
    context: InsightContext,
    threshold: Double
  ) -> Insight? {
    let latestSpend = magnitude(latest.totalExpense)
    let baselineSpend = magnitude(baseline.totalExpense)
    guard baselineSpend > 0 else { return nil }
    let fraction = (latestSpend - baselineSpend) / baselineSpend
    guard abs(fraction) >= threshold else { return nil }

    let increased = fraction > 0
    let deltaAmount = Decimal(-(latestSpend - baselineSpend))
    let monthDate = CategorySpendSeries.monthDate(latest.month) ?? latest.end
    return Insight(
      id: "\(InsightKind.monthOverMonthDelta.rawValue):\(latest.month)",
      kind: .monthOverMonthDelta,
      title: increased
        ? "Spending up \(percent(abs(fraction))) vs \(label)"
        : "Spending down \(percent(abs(fraction))) vs \(label)",
      date: monthDate,
      framing: increased ? .negative : .positive,
      actionability: .informational,
      surprise: min(abs(fraction), 1),
      monetaryImpact: InstrumentAmount(
        quantity: deltaAmount, instrument: context.reportingCurrency),
      facts: [
        InsightFact("This period", context.formatted(Decimal(-latestSpend))),
        InsightFact("Comparison", context.formatted(Decimal(-baselineSpend))),
        InsightFact("Change", "\(increased ? "+" : "−")\(percent(abs(fraction)))"),
      ],
      references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
  }

  private static func magnitude(_ amount: InstrumentAmount) -> Double {
    let value = Double(truncating: amount.quantity as NSDecimalNumber)
    return value < 0 ? -value : 0
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }
}
