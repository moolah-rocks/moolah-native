import Foundation

/// Savings-rate trend (design §D-16): the rolling `(income − expenses) /
/// income` ratio across complete months, with a Mann-Kendall trend test.
/// A rising savings rate is framed positively; a falling one negatively.
enum SavingsRateInsight {
  static func detect(
    monthly: [MonthlyIncomeExpense],
    context: InsightContext,
    minimumMonths: Int = 4
  ) -> [Insight] {
    let complete = InsightAggregates.completeMonths(monthly, context: context)
    let rates: [Double] = complete.compactMap { month in
      let income = Double(truncating: InsightAggregates.incomeMagnitude(month.totalIncome) as NSDecimalNumber)
      guard income > 0 else { return nil }
      let net = Double(truncating: month.totalProfit.quantity as NSDecimalNumber)
      return net / income
    }
    guard rates.count >= minimumMonths, let result = MannKendall.test(rates),
      result.statistic != 0
    else { return [] }

    let latest = rates[rates.count - 1]
    let rising = result.isIncreasing
    // Surface only statistically credible trends (loose threshold — single
    // series, no multiple-comparison family here).
    guard result.pValue <= 0.1 else { return [] }

    return [
      Insight(
        id: "\(InsightKind.savingsRateTrend.rawValue):\(monthKey(context))",
        kind: .savingsRateTrend,
        title: rising ? "Your savings rate is climbing" : "Your savings rate is slipping",
        detail:
          "Over the last \(rates.count) months your savings rate has been "
          + "\(rising ? "rising" : "falling") — currently about \(percent(latest)) of income.",
        date: context.now,
        framing: rising ? .positive : .negative,
        actionability: .review,
        surprise: NormalDistribution.surprise(fromZScore: result.zScore),
        monetaryImpact: nil,
        facts: [
          InsightFact("Current savings rate", percent(latest)),
          InsightFact("Direction", rising ? "Rising" : "Falling"),
          InsightFact("Months analysed", "\(rates.count)"),
          InsightFact("Trend p-value", result.pValue.formatted(.number.precision(.fractionLength(3)))),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  private static func percent(_ fraction: Double) -> String {
    max(fraction, 0).formatted(.percent.precision(.fractionLength(0)))
  }

  private static func monthKey(_ context: InsightContext) -> String {
    FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd)
  }
}
