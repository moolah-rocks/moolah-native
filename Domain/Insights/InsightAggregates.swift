import Foundation

/// Shared roll-ups over the monthly aggregates and daily-balance series,
/// computed once and reused by the cash-flow, savings, and income detectors
/// so each doesn't re-derive "average monthly spend" from scratch.
enum InsightAggregates {
  /// Complete (not in-progress) financial months, ascending by bucket.
  static func completeMonths(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext
  ) -> [MonthlyIncomeExpense] {
    let currentBucket = FinancialMonth.key(
      for: context.now, monthEnd: context.financialMonthEnd)
    return monthly.filter { $0.month < currentBucket }.sorted { $0.month < $1.month }
  }

  /// Mean spend magnitude (positive) over the trailing `months` complete
  /// months. `nil` when there's no complete month.
  static func averageMonthlySpend(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext, months: Int = 6
  ) -> Decimal? {
    let recent = completeMonths(monthly, context: context).suffix(months)
    guard !recent.isEmpty else { return nil }
    let total = recent.reduce(Decimal(0)) { $0 + spendMagnitude($1.totalExpense) }
    return total / Decimal(recent.count)
  }

  /// Mean income magnitude (positive) over the trailing `months` complete
  /// months. `nil` when there's no complete month.
  static func averageMonthlyIncome(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext, months: Int = 6
  ) -> Decimal? {
    let recent = completeMonths(monthly, context: context).suffix(months)
    guard !recent.isEmpty else { return nil }
    let total = recent.reduce(Decimal(0)) { $0 + incomeMagnitude($1.totalIncome) }
    return total / Decimal(recent.count)
  }

  /// Mean signed net (income + expense; positive = surplus) over the
  /// trailing `months` complete months. `nil` when there's no complete month.
  static func averageMonthlyNet(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext, months: Int = 6
  ) -> Decimal? {
    let recent = completeMonths(monthly, context: context).suffix(months)
    guard !recent.isEmpty else { return nil }
    let total = recent.reduce(Decimal(0)) { $0 + $1.totalProfit.quantity }
    return total / Decimal(recent.count)
  }

  /// Most recent historical (non-forecast) daily balance.
  static func latestActual(_ balances: [DailyBalance]) -> DailyBalance? {
    balances.filter { !$0.isForecast }.max { $0.date < $1.date }
  }

  /// Positive spend magnitude from a signed (negative) expense amount; a
  /// net-refund period clamps to zero.
  static func spendMagnitude(_ amount: InstrumentAmount) -> Decimal {
    amount.quantity < 0 ? -amount.quantity : 0
  }

  /// Positive income magnitude from a signed income amount.
  static func incomeMagnitude(_ amount: InstrumentAmount) -> Decimal {
    amount.quantity > 0 ? amount.quantity : 0
  }
}
