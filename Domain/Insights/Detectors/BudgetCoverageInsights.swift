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
    for transaction in input.transactions where transaction.isExpense {
      let age = context.daysSince(transaction.date)
      guard age >= 0, age <= windowDays, let categoryId = transaction.categoryId,
        !input.budgetedCategoryIds.contains(categoryId)
      else { continue }
      spendByCategory[categoryId, default: 0] +=
        Double(truncating: transaction.spendMagnitude as NSDecimalNumber)
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
