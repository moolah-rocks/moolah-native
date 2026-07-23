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
    guard !complete.contains(where: \.hasUnavailableData) else { return [] }
    let ratedMonths: [(month: MonthlyIncomeExpense, rate: Double)] = complete.compactMap { month in
      let income = Double(
        truncating: InsightAggregates.incomeMagnitude(month.totalIncome) as NSDecimalNumber)
      guard income > 0 else { return nil }
      let net = Double(truncating: month.totalProfit.quantity as NSDecimalNumber)
      return (month, net / income)
    }
    let points = ratedMonths.compactMap { item in
      FinancialMonth.date(forKey: item.month.month).map {
        InsightChart.Point(date: $0, value: item.rate)
      }
    }
    let rates = ratedMonths.map(\.rate)
    guard rates.count >= minimumMonths, let result = MannKendall.test(rates),
      result.statistic != 0
    else { return [] }

    let latest = rates[rates.count - 1]
    guard let latestMonth = ratedMonths.last,
      let throughMonth = context.formattedFinancialMonth(latestMonth.month.month)
    else { return [] }
    let rising = result.isIncreasing
    // Surface only statistically credible trends (loose threshold — single
    // series, no multiple-comparison family here).
    guard result.pValue <= 0.1 else { return [] }

    return [
      Insight(
        id: "\(InsightKind.savingsRateTrend.rawValue):\(monthKey(context))",
        presentationKey:
          "\(InsightKind.savingsRateTrend.rawValue):\(rising ? "rising" : "falling")",
        kind: .savingsRateTrend,
        title: rising ? "Your savings rate is climbing" : "Your savings rate is slipping",
        date: context.now,
        framing: rising ? .positive : .negative,
        actionability: .review,
        surprise: NormalDistribution.surprise(fromZScore: result.zScore),
        monetaryImpact: nil,
        facts: [
          InsightFact("Current savings rate", percent(latest)),
          InsightFact("Direction", rising ? "Rising" : "Falling"),
          InsightFact("Months analysed", "\(rates.count)"),
          InsightFact("Through month", throughMonth),
          InsightFact(
            "Trend p-value", result.pValue.formatted(.number.precision(.fractionLength(3)))),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.savingsRate(points: points))
    ]
  }

  private static func percent(_ fraction: Double) -> String {
    max(fraction, 0).formatted(.percent.precision(.fractionLength(0)))
  }

  private static func monthKey(_ context: InsightContext) -> String {
    FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd)
  }
}
