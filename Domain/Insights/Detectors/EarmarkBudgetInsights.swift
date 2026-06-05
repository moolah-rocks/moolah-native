import Foundation

/// Earmark (budget) performance insights (design §E): burndown projection
/// (18) and the positive-framed under-spend counterpart (19). Both
/// linearly extrapolate spend across the budget window — the under-spend
/// branch is what keeps the feature from reading as a scold.
enum EarmarkBudgetInsights {
  static func detect(
    earmarks: [EarmarkSnapshot],
    context: InsightContext,
    overspendTolerance: Double = 0.05,
    underspendTolerance: Double = 0.1
  ) -> [Insight] {
    var insights: [Insight] = []
    for earmark in earmarks where !earmark.isHidden {
      guard let budget = earmark.budget, budget.quantity > 0,
        let spent = earmark.spent,
        let window = window(for: earmark, context: context),
        let projection = project(spent: spent, budget: budget, window: window, context: context)
      else { continue }

      let remaining = projection.budgetMagnitude - projection.spentMagnitude
      let chart = InsightChartBuilders.earmarkBurndown(
        budget: projection.budgetMagnitude,
        current: InsightChart.Point(date: context.now, value: remaining),
        projectedRemaining: projection.budgetMagnitude - projection.projected,
        window: DateInterval(start: window.start, end: window.end),
        reportingCurrency: context.reportingCurrency)

      if projection.fraction > 1 + overspendTolerance {
        insights.append(
          overspend(earmark, budget: budget, projection: projection, context: context, chart: chart)
        )
      } else if projection.fraction < 1 - underspendTolerance, projection.elapsedFraction >= 0.5 {
        insights.append(
          underspend(
            earmark, budget: budget, projection: projection, context: context, chart: chart))
      }
    }
    return insights
  }

  // MARK: - Projection

  private struct Window {
    let start: Date
    let end: Date
  }

  /// Linear burndown projection of a budget window.
  private struct Projection {
    let spentMagnitude: Double
    let projected: Double
    let budgetMagnitude: Double
    let fraction: Double
    let elapsedFraction: Double
  }

  private static func project(
    spent: InstrumentAmount, budget: InstrumentAmount, window: Window, context: InsightContext
  ) -> Projection? {
    let calendar = context.calendar
    let totalDays = max(
      calendar.dateComponents([.day], from: window.start, to: window.end).day ?? 0, 1)
    let elapsedRaw = calendar.dateComponents([.day], from: window.start, to: context.now).day ?? 0
    let elapsedDays = min(max(elapsedRaw, 0), totalDays)
    guard elapsedDays > 0, elapsedDays < totalDays else { return nil }

    let elapsedFraction = Double(elapsedDays) / Double(totalDays)
    // `EarmarkSnapshot.spent` is already a positive magnitude; clamp a stray
    // negative to zero rather than re-flipping it.
    let spentMagnitude = max(toDouble(spent.quantity), 0)
    let budgetMagnitude = toDouble(budget.quantity)
    guard budgetMagnitude > 0 else { return nil }
    let projected = spentMagnitude / elapsedFraction
    return Projection(
      spentMagnitude: spentMagnitude,
      projected: projected,
      budgetMagnitude: budgetMagnitude,
      fraction: projected / budgetMagnitude,
      elapsedFraction: elapsedFraction)
  }

  // MARK: - Insight construction

  private static func overspend(
    _ earmark: EarmarkSnapshot,
    budget: InstrumentAmount,
    projection: Projection,
    context: InsightContext,
    chart: InsightChart?
  ) -> Insight {
    let overBy = Decimal(projection.projected - projection.budgetMagnitude)
    return Insight(
      id: "\(InsightKind.earmarkBurndownProjection.rawValue):\(earmark.id.uuidString)",
      kind: .earmarkBurndownProjection,
      title: "\(earmark.name) heading over budget",
      date: context.now,
      framing: .negative,
      actionability: .act,
      surprise: min(projection.fraction - 1, 1),
      monetaryImpact: InstrumentAmount(quantity: -overBy, instrument: context.reportingCurrency),
      facts: projectionFacts(budget: budget, projection: projection, context: context),
      references: InsightReferences(earmarkIds: [earmark.id]),
      chart: chart)
  }

  private static func underspend(
    _ earmark: EarmarkSnapshot,
    budget: InstrumentAmount,
    projection: Projection,
    context: InsightContext,
    chart: InsightChart?
  ) -> Insight {
    let roomToSpare = Decimal(projection.budgetMagnitude - projection.projected)
    return Insight(
      id: "\(InsightKind.earmarkUnderspend.rawValue):\(earmark.id.uuidString)",
      kind: .earmarkUnderspend,
      title: "Room to spare in \(earmark.name)",
      date: context.now,
      framing: .positive,
      actionability: .informational,
      surprise: min(1 - projection.fraction, 1),
      monetaryImpact: InstrumentAmount(
        quantity: roomToSpare, instrument: context.reportingCurrency),
      facts: projectionFacts(budget: budget, projection: projection, context: context),
      references: InsightReferences(earmarkIds: [earmark.id]),
      chart: chart)
  }

  private static func projectionFacts(
    budget: InstrumentAmount, projection: Projection, context: InsightContext
  ) -> [InsightFact] {
    [
      InsightFact("Budget", context.formatted(budget)),
      InsightFact("Spent so far", context.formatted(Decimal(projection.spentMagnitude))),
      InsightFact("Projected", context.formatted(Decimal(projection.projected))),
      InsightFact(
        "Window elapsed",
        projection.elapsedFraction.formatted(.percent.precision(.fractionLength(0)))),
    ]
  }

  /// Budget window: the explicit savings window when set, otherwise the
  /// current calendar month (a pragmatic default for monthly budgets that
  /// don't carry an explicit window — documented simplification).
  private static func window(for earmark: EarmarkSnapshot, context: InsightContext) -> Window? {
    if let start = earmark.savingsStartDate, let end = earmark.savingsEndDate, start < end {
      return Window(start: start, end: end)
    }
    let calendar = context.calendar
    let components = calendar.dateComponents([.year, .month], from: context.now)
    guard let start = calendar.date(from: components),
      let range = calendar.range(of: .day, in: .month, for: context.now),
      let end = calendar.date(byAdding: .day, value: range.count, to: start)
    else { return nil }
    return Window(start: start, end: end)
  }

  private static func toDouble(_ value: Decimal) -> Double {
    Double(truncating: value as NSDecimalNumber)
  }
}
