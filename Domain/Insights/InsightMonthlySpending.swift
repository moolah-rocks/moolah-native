import Foundation

/// Posted expense legs for one financial month, in the reporting currency.
/// This measures spending rather than changes to available funds: earmarked
/// bills count as expenses, while transfers and trades do not.
struct InsightMonthlySpending: Sendable, Hashable {
  let month: String
  let start: Date
  let end: Date
  /// Signed expense total, including positive refunds.
  let expense: InstrumentAmount
  let hasUnavailableData: Bool

  /// Daily values are already converted at historic rates. Failed days
  /// mark only their own financial month unavailable, including days with
  /// no convertible inputs.
  static func aggregate(
    _ daily: [DailySpendSummary], unavailableDays: Set<Date>, context: InsightContext
  ) -> [InsightMonthlySpending] {
    let failedDays = unavailableDays.map {
      DailySpendSummary(day: $0, expense: context.zero, income: context.zero)
    }
    let buckets = Dictionary(grouping: daily + failedDays) {
      FinancialMonth.key(for: $0.day, monthEnd: context.financialMonthEnd)
    }
    return buckets.compactMap { key, days in
      guard let start = days.map(\.day).min(), let end = days.map(\.day).max() else {
        return nil
      }
      return InsightMonthlySpending(
        month: key,
        start: start,
        end: end,
        expense: days.reduce(context.zero) { $0 + $1.expense },
        hasUnavailableData: days.contains { unavailableDays.contains($0.day) })
    }.sorted { $0.month < $1.month }
  }
}
