import Foundation

/// Budget-coverage insight (research follow-up §F-2): the user budgets some
/// categories but a large spend category has no budget line. Bridges spend
/// analysis and the earmark-budgeting feature with an actionable nudge.
enum BudgetCoverageInsights {
  static func unbudgetedCategory(
    _ input: InsightInput,
    windowDays: Int = 90
  ) -> [Insight] {
    // Only relevant once the user actually budgets something.
    guard !input.budgetedCategoryIds.isEmpty else { return [] }
    let context = input.context

    var spendByCategory: [UUID: Double] = [:]
    for summary in input.unbudgetedCategorySpend {
      guard let categoryId = summary.categoryId,
        !input.budgetedCategoryIds.contains(categoryId)
      else { continue }
      let magnitude = summary.total.quantity < 0 ? -summary.total.quantity : 0
      spendByCategory[categoryId, default: 0] += Double(truncating: magnitude as NSDecimalNumber)
    }
    guard let top = spendByCategory.max(by: { $0.value < $1.value }), top.value > 0 else {
      return []
    }
    let categoryName =
      input.categories.by(id: top.key).map { input.categories.path(for: $0) }
      ?? "A category"

    return [
      Insight(
        id: "\(InsightKind.unbudgetedCategory.rawValue):\(top.key.uuidString)",
        kind: .unbudgetedCategory,
        title: "\(categoryName) has no budget",
        detail:
          "You spent \(context.formatted(Decimal(-top.value))) on \(categoryName) in the last "
          + "\(windowDays) days, but it isn't in any budget. Adding one would keep it in check.",
        date: context.now,
        framing: .neutral,
        actionability: .review,
        surprise: 0.4,
        monetaryImpact: InstrumentAmount(
          quantity: Decimal(-top.value), instrument: context.reportingCurrency),
        facts: [
          InsightFact("Category", categoryName),
          InsightFact("Spent (\(windowDays)d)", context.formatted(Decimal(-top.value))),
        ],
        references: InsightReferences(
          categoryIds: [top.key], instrumentIds: [context.reportingCurrency.id]))
    ]
  }
}
