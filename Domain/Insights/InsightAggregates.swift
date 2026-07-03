import Foundation

/// Shared roll-ups over the monthly aggregates and daily-balance series,
/// computed once and reused by the cash-flow, savings, and income detectors
/// so each doesn't re-derive "typical monthly spend" from scratch.
enum InsightAggregates {
  /// Complete (not in-progress) financial months, ascending by bucket.
  static func completeMonths(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext
  ) -> [MonthlyIncomeExpense] {
    let currentBucket = FinancialMonth.key(
      for: context.now, monthEnd: context.financialMonthEnd)
    return monthly.filter { $0.month < currentBucket }.sorted { $0.month < $1.month }
  }

  /// Typical (median) spend magnitude (positive) over the trailing `months`
  /// complete months. Median, not mean, so a single heavy month doesn't skew
  /// the "typical" figure the liquidity detectors quote and budget against.
  /// `nil` when there's no complete month.
  static func typicalMonthlySpend(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext, months: Int = 6
  ) -> Decimal? {
    let recent = completeMonths(monthly, context: context).suffix(months)
    guard !recent.isEmpty else { return nil }
    return typicalDecimal(recent.map { spendMagnitude($0.totalExpense) })
  }

  /// Typical (median) income magnitude (positive) over the trailing `months`
  /// complete months. Median, not mean, so a one-off bonus month doesn't lift
  /// the baseline. `nil` when there's no complete month.
  static func typicalMonthlyIncome(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext, months: Int = 6
  ) -> Decimal? {
    let recent = completeMonths(monthly, context: context).suffix(months)
    guard !recent.isEmpty else { return nil }
    return typicalDecimal(recent.map { incomeMagnitude($0.totalIncome) })
  }

  /// Typical (median) signed net (income + expense; positive = surplus) over
  /// the trailing `months` complete months. Median, not mean, so one unusual
  /// month doesn't distort the burn / surplus estimate. `nil` when there's no
  /// complete month.
  static func typicalMonthlyNet(
    _ monthly: [MonthlyIncomeExpense], context: InsightContext, months: Int = 6
  ) -> Decimal? {
    let recent = completeMonths(monthly, context: context).suffix(months)
    guard !recent.isEmpty else { return nil }
    return typicalDecimal(recent.map { $0.totalProfit.quantity })
  }

  /// Median of a `Decimal` sample, expressed back as a `Decimal`. Converts at
  /// the boundary and delegates to `DescriptiveStatistics.median` per that
  /// module's `[Double]` contract — these month totals are already lossy
  /// multi-currency aggregates, so the round-trip loses nothing meaningful.
  /// Assumes a non-empty input — callers guard for emptiness first.
  private static func typicalDecimal(_ values: [Decimal]) -> Decimal {
    let doubles = values.map { Double(truncating: $0 as NSDecimalNumber) }
    return Decimal(DescriptiveStatistics.median(doubles))
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
