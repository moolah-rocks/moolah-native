import Foundation

/// Category-mix shift (design §C-12): a category whose share of total spend
/// moved by more than `minimumShiftPoints` percentage points between the
/// most recent complete month and the month before. Surfaces only the
/// largest shifts to avoid flooding (a mix shift is informational, not
/// actionable).
enum CategoryMixShiftInsight {
  static func detect(
    breakdown: [ExpenseBreakdown],
    categories: Categories,
    context: InsightContext,
    minimumShiftPoints: Double = 0.08,
    maximumResults: Int = 2
  ) -> [Insight] {
    let currentBucket = FinancialMonth.key(
      for: context.now, monthEnd: context.financialMonthEnd)
    let completeMonths = Set(breakdown.map(\.month)).filter { $0 < currentBucket }.sorted()
    guard completeMonths.count >= 2 else { return [] }
    let recentMonth = completeMonths[completeMonths.count - 1]
    let priorMonth = completeMonths[completeMonths.count - 2]

    let recent = shares(in: breakdown, month: recentMonth)
    let prior = shares(in: breakdown, month: priorMonth)
    guard recent.total > 0, prior.total > 0 else { return [] }

    let categoryIds = Set(recent.byCategory.keys).union(prior.byCategory.keys)
    var shifts: [Shift] = []
    for categoryId in categoryIds {
      let recentShare = recent.byCategory[categoryId] ?? 0
      let priorShare = prior.byCategory[categoryId] ?? 0
      let shift = recentShare - priorShare
      if abs(shift) >= minimumShiftPoints {
        shifts.append(Shift(categoryId: categoryId, shift: shift, recentShare: recentShare))
      }
    }

    return
      shifts
      .sorted { abs($0.shift) > abs($1.shift) }
      .prefix(maximumResults)
      .map { makeInsight($0, recentMonth: recentMonth, categories: categories, context: context) }
  }

  /// One category's share movement between the two compared months.
  private struct Shift {
    let categoryId: UUID
    let shift: Double
    let recentShare: Double
  }

  private struct ShareBreakdown {
    let total: Double
    let byCategory: [UUID: Double]
  }

  private static func shares(in breakdown: [ExpenseBreakdown], month: String) -> ShareBreakdown {
    var magnitudes: [UUID: Double] = [:]
    var total = 0.0
    for row in breakdown where row.month == month {
      let signed = Double(truncating: row.totalExpenses.quantity as NSDecimalNumber)
      let magnitude = max(-signed, 0)
      let key = row.categoryId ?? CategorySpendSeries.uncategorizedKey
      magnitudes[key, default: 0] += magnitude
      total += magnitude
    }
    guard total > 0 else { return ShareBreakdown(total: 0, byCategory: [:]) }
    let shares = magnitudes.mapValues { $0 / total }
    return ShareBreakdown(total: total, byCategory: shares)
  }

  private static func makeInsight(
    _ shift: Shift,
    recentMonth: String,
    categories: Categories,
    context: InsightContext
  ) -> Insight {
    let resolved =
      shift.categoryId == CategorySpendSeries.uncategorizedKey
      ? nil : categories.by(id: shift.categoryId)
    let categoryName = resolved.map { categories.path(for: $0) } ?? "Uncategorized"
    let grew = shift.shift > 0
    let monthDate = CategorySpendSeries.monthDate(recentMonth) ?? context.now
    return Insight(
      id: "\(InsightKind.categoryMixShift.rawValue):\(shift.categoryId.uuidString):\(recentMonth)",
      kind: .categoryMixShift,
      title: "\(categoryName) is a \(grew ? "bigger" : "smaller") slice",
      detail:
        "\(categoryName) is now \(percent(shift.recentShare)) of your spending, "
        + "\(grew ? "up" : "down") \(points(abs(shift.shift))) from the month before.",
      date: monthDate,
      framing: .neutral,
      actionability: .informational,
      surprise: min(abs(shift.shift) * 3, 1),
      monetaryImpact: nil,
      facts: [
        InsightFact("Category", categoryName),
        InsightFact("Current share", percent(shift.recentShare)),
        InsightFact("Change", "\(grew ? "+" : "−")\(points(abs(shift.shift)))"),
      ],
      references: InsightReferences(
        categoryIds: resolved.map { [$0.id] } ?? []))
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }

  private static func points(_ fraction: Double) -> String {
    "\((fraction * 100).formatted(.number.precision(.fractionLength(0)))) pts"
  }
}
