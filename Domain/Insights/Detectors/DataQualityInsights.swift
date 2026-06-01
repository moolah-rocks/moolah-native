import Foundation

/// Data-quality insights (research follow-up §B-1, §C-1). These don't quantify
/// money — they protect the inputs every *other* detector relies on. A large
/// uncategorized backlog blinds the category detectors; unmerged transfers
/// double-count as phantom income + expense and distort spend, savings-rate,
/// and trend figures.
enum DataQualityInsights {
  /// Nudge to categorize a backlog of imported transactions (C-1).
  static func uncategorizedBacklog(
    _ input: InsightInput, minimumCount: Int = 10
  ) -> [Insight] {
    let count = input.uncategorizedTransactionCount
    guard count >= minimumCount else { return [] }
    let context = input.context
    return [
      Insight(
        id: "\(InsightKind.uncategorizedBacklog.rawValue):\(monthKey(context))",
        kind: .uncategorizedBacklog,
        title: "\(count) transactions need a category",
        detail:
          "Categorizing your \(count) uncategorized transactions will sharpen your "
          + "spending breakdowns and the insights built on them.",
        date: context.now,
        framing: .neutral,
        actionability: .review,
        surprise: min(Double(count) / 100, 0.6),
        monetaryImpact: nil,
        facts: [InsightFact("Uncategorized", "\(count)")],
        references: InsightReferences())
    ]
  }

  /// Flag a backlog of unmerged transfer suggestions (B-1).
  static func unreconciledTransfers(
    _ input: InsightInput, minimumCount: Int = 3
  ) -> [Insight] {
    let count = input.pendingTransferCount
    guard count >= minimumCount else { return [] }
    let context = input.context
    let agedText =
      input.oldestPendingTransferDate.map { date -> String in
        let days = context.daysSince(date)
        return days > 0 ? " The oldest has been waiting \(days) days." : ""
      } ?? ""
    return [
      Insight(
        id: "\(InsightKind.unreconciledTransfers.rawValue):\(monthKey(context))",
        kind: .unreconciledTransfers,
        title: "\(count) transfers waiting to be merged",
        detail:
          "You have \(count) likely transfers between your own accounts that aren't "
          + "merged yet — until they are, they inflate your income and spending."
          + agedText,
        date: context.now,
        framing: .neutral,
        actionability: .act,
        surprise: min(Double(count) / 20, 0.6),
        monetaryImpact: nil,
        facts: [InsightFact("Pending transfers", "\(count)")],
        references: InsightReferences())
    ]
  }

  private static func monthKey(_ context: InsightContext) -> String {
    FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd)
  }
}
