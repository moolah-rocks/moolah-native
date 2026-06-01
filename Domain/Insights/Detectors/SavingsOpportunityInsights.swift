import Foundation

/// Savings-opportunity insights (design §F): fee spend (22) and
/// subscription overspend (23). Both quantify recurring leakage the user can
/// act on.
enum SavingsOpportunityInsights {
  /// Category-name keywords that flag a leg as a bank/finance fee. Matched
  /// case-insensitively against the full category path so a nested
  /// "Banking:Fees" category is caught.
  private static let feeKeywords = [
    "fee", "charge", "interest", "atm", "overdraft", "surcharge", "penalty",
  ]

  /// Total spend in fee-like categories over the trailing year (22).
  static func feeSpend(
    transactions: [InsightTransaction],
    context: InsightContext,
    lookbackDays: Int = 365
  ) -> [Insight] {
    let fees = transactions.filter { transaction in
      transaction.isExpense
        && context.daysSince(transaction.date) >= 0
        && context.daysSince(transaction.date) <= lookbackDays
        && isFeeCategory(transaction.categoryPath)
    }
    guard !fees.isEmpty else { return [] }
    let total = fees.reduce(Decimal(0)) { $0 + $1.spendMagnitude }
    guard total > 0 else { return [] }

    let categoryIds = Array(Set(fees.compactMap(\.categoryId)))
    return [
      Insight(
        id: "\(InsightKind.feeSpend.rawValue):\(FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd))",
        kind: .feeSpend,
        title: "You paid \(context.formatted(Decimal(-toDouble(total)))) in fees",
        detail:
          "Over the past year you've paid about \(context.formatted(Decimal(-toDouble(total)))) "
          + "in fees and charges across \(fees.count) transactions. Many of these are avoidable.",
        date: context.now,
        framing: .negative,
        actionability: .review,
        surprise: 0.5,
        monetaryImpact: InstrumentAmount(quantity: -total, instrument: context.reportingCurrency),
        facts: [
          InsightFact("Annual fees", context.formatted(Decimal(-toDouble(total)))),
          InsightFact("Transactions", "\(fees.count)"),
        ],
        references: InsightReferences(
          categoryIds: categoryIds, instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  /// Subscriptions as a share of income (23). Flags when the combined
  /// monthly subscription cost exceeds `threshold` of average monthly income.
  static func subscriptionOverspend(
    subscriptions: [DetectedSubscription],
    averageMonthlyIncome: Decimal?,
    context: InsightContext,
    threshold: Double = 0.15
  ) -> [Insight] {
    let expenseStreams = subscriptions.filter { !$0.isIncome }
    guard !expenseStreams.isEmpty, let income = averageMonthlyIncome, income > 0 else { return [] }
    let monthlyTotal = expenseStreams.reduce(Decimal(0)) { $0 + $1.monthlyCostMagnitude }
    let share = toDouble(monthlyTotal) / toDouble(income)
    guard share > threshold else { return [] }

    return [
      Insight(
        id: "\(InsightKind.subscriptionOverspend.rawValue):\(FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd))",
        kind: .subscriptionOverspend,
        title: "Subscriptions are \(percent(share)) of income",
        detail:
          "Your \(expenseStreams.count) subscriptions cost about "
          + "\(context.formatted(monthlyTotal))/month — \(percent(share)) of your income. "
          + "Trimming a few could free up real cash.",
        date: context.now,
        framing: .negative,
        actionability: .review,
        surprise: min(share, 1),
        monetaryImpact: InstrumentAmount(quantity: -monthlyTotal, instrument: context.reportingCurrency),
        facts: [
          InsightFact("Monthly subscriptions", context.formatted(monthlyTotal)),
          InsightFact("Share of income", percent(share)),
          InsightFact("Active subscriptions", "\(expenseStreams.count)"),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  private static func isFeeCategory(_ path: String?) -> Bool {
    guard let path = path?.lowercased() else { return false }
    return feeKeywords.contains { path.contains($0) }
  }

  private static func toDouble(_ value: Decimal) -> Double {
    Double(truncating: value as NSDecimalNumber)
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }
}
