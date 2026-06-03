import Foundation

/// Savings-goal ETA (design §E-20): at the current contribution rate, when
/// will the goal be reached. A reached goal is the positive-framed
/// celebration; an in-progress goal projects a target date from the saved
/// amount accrued since the goal's start.
enum SavingsGoalInsight {
  static func detect(
    earmarks: [EarmarkSnapshot],
    context: InsightContext
  ) -> [Insight] {
    earmarks.compactMap { earmark in
      guard !earmark.isHidden, let goal = earmark.savingsGoal, goal.quantity > 0,
        let saved = earmark.saved
      else { return nil }
      return evaluate(earmark: earmark, goal: goal, saved: saved, context: context)
    }
  }

  private static func evaluate(
    earmark: EarmarkSnapshot,
    goal: InstrumentAmount,
    saved: InstrumentAmount,
    context: InsightContext
  ) -> Insight? {
    if saved.quantity >= goal.quantity {
      return reached(earmark, goal: goal, saved: saved, context: context)
    }
    let progress = ratio(saved.quantity, goal.quantity)
    guard let etaDate = projectedCompletion(earmark, goal: goal, saved: saved, context: context)
    else {
      return progressOnly(earmark, goal: goal, saved: saved, progress: progress, context: context)
    }
    return eta(earmark, goal: goal, saved: saved, date: etaDate, context: context)
  }

  /// Project the completion date from the contribution rate since the goal
  /// started. `nil` when there's no start date or no positive accrual.
  private static func projectedCompletion(
    _ earmark: EarmarkSnapshot,
    goal: InstrumentAmount,
    saved: InstrumentAmount,
    context: InsightContext
  ) -> Date? {
    guard let start = earmark.savingsStartDate else { return nil }
    let elapsedDays = context.calendar.dateComponents([.day], from: start, to: context.now).day ?? 0
    guard elapsedDays > 0 else { return nil }
    let ratePerDay = toDouble(saved.quantity) / Double(elapsedDays)
    guard ratePerDay > 0 else { return nil }
    let remaining = toDouble(goal.quantity - saved.quantity)
    let daysToGoal = Int((remaining / ratePerDay).rounded())
    return context.calendar.date(byAdding: .day, value: daysToGoal, to: context.now)
  }

  // MARK: - Insight construction

  private static func reached(
    _ earmark: EarmarkSnapshot,
    goal: InstrumentAmount,
    saved: InstrumentAmount,
    context: InsightContext
  ) -> Insight {
    Insight(
      id: "\(InsightKind.savingsGoalETA.rawValue):reached:\(earmark.id.uuidString)",
      kind: .savingsGoalETA,
      title: "\(earmark.name) goal reached 🎉",
      date: context.now,
      framing: .positive,
      actionability: .informational,
      surprise: 0.5,
      monetaryImpact: goal,
      facts: [
        InsightFact("Goal", context.formatted(goal)),
        InsightFact("Saved", context.formatted(saved)),
      ],
      references: InsightReferences(earmarkIds: [earmark.id]))
  }

  private static func eta(
    _ earmark: EarmarkSnapshot,
    goal: InstrumentAmount,
    saved: InstrumentAmount,
    date: Date,
    context: InsightContext
  ) -> Insight {
    let progress = ratio(saved.quantity, goal.quantity)
    let etaText = date.formatted(.dateTime.month(.abbreviated).year())
    return Insight(
      id: "\(InsightKind.savingsGoalETA.rawValue):eta:\(earmark.id.uuidString)",
      kind: .savingsGoalETA,
      title: "\(earmark.name): on track for \(etaText)",
      date: context.now,
      framing: .positive,
      actionability: .informational,
      surprise: 0.3,
      monetaryImpact: saved,
      facts: [
        InsightFact("Goal", context.formatted(goal)),
        InsightFact("Saved", context.formatted(saved)),
        InsightFact("Progress", percent(progress)),
        InsightFact("Projected completion", etaText),
      ],
      references: InsightReferences(earmarkIds: [earmark.id]))
  }

  private static func progressOnly(
    _ earmark: EarmarkSnapshot,
    goal: InstrumentAmount,
    saved: InstrumentAmount,
    progress: Double,
    context: InsightContext
  ) -> Insight? {
    // Only celebrate meaningful progress; an untouched goal isn't news.
    guard progress >= 0.5 else { return nil }
    return Insight(
      id: "\(InsightKind.savingsGoalETA.rawValue):progress:\(earmark.id.uuidString)",
      kind: .savingsGoalETA,
      title: "\(earmark.name) is \(percent(progress)) of the way there",
      date: context.now,
      framing: .positive,
      actionability: .informational,
      surprise: 0.25,
      monetaryImpact: saved,
      facts: [
        InsightFact("Goal", context.formatted(goal)),
        InsightFact("Saved", context.formatted(saved)),
        InsightFact("Progress", percent(progress)),
      ],
      references: InsightReferences(earmarkIds: [earmark.id]))
  }

  private static func ratio(_ numerator: Decimal, _ denominator: Decimal) -> Double {
    guard denominator != 0 else { return 0 }
    return toDouble(numerator) / toDouble(denominator)
  }

  private static func toDouble(_ value: Decimal) -> Double {
    Double(truncating: value as NSDecimalNumber)
  }

  private static func percent(_ fraction: Double) -> String {
    min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
  }
}
