import Foundation

/// New-merchant alert (design §B-8): a payee seen for the first time in the
/// recent window whose charge lands in the top decile of all historical
/// spend. Novelty × magnitude — a first-time small charge isn't worth a
/// notification, a first-time large one is.
enum NewMerchantInsight {
  static func detect(
    transactions: [InsightTransaction],
    context: InsightContext,
    windowDays: Int = 7,
    magnitudePercentile: Double = 0.9
  ) -> [Insight] {
    let expenses = transactions.filter(\.isExpense)
    guard expenses.count >= 10 else { return [] }

    let magnitudes = expenses.map { Double(truncating: $0.spendMagnitude as NSDecimalNumber) }
    let topDecile = DescriptiveStatistics.percentile(magnitudes, magnitudePercentile)

    // Payees seen before the window opened.
    var historicalPayees: Set<String> = []
    for transaction in expenses where context.daysSince(transaction.date) > windowDays {
      if !transaction.normalizedPayee.isEmpty {
        historicalPayees.insert(transaction.normalizedPayee)
      }
    }

    var seenThisWindow: Set<String> = []
    var insights: [Insight] = []
    for transaction in expenses.sorted(by: { $0.date > $1.date }) {
      let age = context.daysSince(transaction.date)
      guard age >= 0, age <= windowDays else { continue }
      let key = transaction.normalizedPayee
      guard !key.isEmpty, !historicalPayees.contains(key),
        !seenThisWindow.contains(key)
      else { continue }
      seenThisWindow.insert(key)

      let value = Double(truncating: transaction.spendMagnitude as NSDecimalNumber)
      guard value >= topDecile, value > 0 else { continue }

      insights.append(
        Insight(
          id: "\(InsightKind.newMerchantAlert.rawValue):\(key)",
          kind: .newMerchantAlert,
          title: "First charge from \(payeeName(transaction))",
          detail:
            "\(context.formatted(transaction.amount)) at \(payeeName(transaction)) — a "
            + "merchant you haven't paid before, and a sizable one.",
          date: transaction.date,
          framing: .neutral,
          actionability: .review,
          surprise: 0.5,
          monetaryImpact: transaction.amountInReportingCurrency(context),
          facts: [
            InsightFact("Merchant", payeeName(transaction)),
            InsightFact("Amount", context.formatted(transaction.amount)),
            InsightFact("Top-decile threshold", context.formatted(Decimal(-topDecile))),
          ],
          references: InsightReferences(
            accountIds: transaction.accountId.map { [$0] } ?? [],
            categoryIds: transaction.categoryId.map { [$0] } ?? [],
            transactionIds: [transaction.id])))
    }
    return insights
  }

  private static func payeeName(_ transaction: InsightTransaction) -> String {
    transaction.rawPayee ?? "a new merchant"
  }
}
