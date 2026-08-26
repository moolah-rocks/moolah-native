import Foundation

/// New-merchant alert (design §B-8): a payee seen for the first time in the
/// recent window, has appeared again, and whose first charge lands in the top
/// decile of all historical spend. Novelty × recurrence × magnitude — a
/// one-off payment or a first-time small charge isn't worth a notification.
///
/// The magnitude baseline (`categorySamples`) only covers categorised
/// expense legs (the SQL filters `category_id IS NOT NULL`), so uncategorised
/// spend is excluded from the top-decile threshold. "New" is approximated as
/// "not seen earlier than the window within the ~13-month payee window": a
/// payee whose earliest `PayeeSummary` occurrence predates the window is
/// established; everything else is treated as new.
enum NewMerchantInsight {
  static func detect(
    recentCandidates: [InsightTransaction],
    payees: [PayeeSummary],
    categorySamples: [CategorySpendSamples],
    context: InsightContext,
    windowDays: Int = 7,
    historyWindowDays: Int = 395,
    magnitudePercentile: Double = 0.9
  ) -> [Insight] {
    let union = categorySamples.flatMap(\.magnitudes).map {
      Double(truncating: $0 as NSDecimalNumber)
    }
    guard union.count >= 10 else { return [] }
    let topDecile = DescriptiveStatistics.percentile(union, magnitudePercentile)

    // Payees whose earliest occurrence predates the window are established.
    // Only expense payees suppress a new-merchant alert — an income payee
    // with the same normalized name must not hide a first-time expense charge.
    var established: Set<String> = []
    let unavailable = unavailableExpensePayees(payees)
    let repeated = repeatedExpensePayees(
      recentCandidates, context: context, windowDays: windowDays)
    for payee in payees
    where payee.isExpense
      && !payee.normalizedPayee.isEmpty
      && context.daysSince(payee.firstSeen) > windowDays
    {
      established.insert(payee.normalizedPayee)
    }

    var seenThisWindow: Set<String> = []
    var insights: [Insight] = []
    for transaction in recentCandidates.filter(\.isExpense).sorted(by: { $0.date < $1.date }) {
      let age = context.daysSince(transaction.date)
      guard age >= 0, age <= windowDays else { continue }
      let key = transaction.normalizedPayee
      guard !key.isEmpty, repeated.contains(key), !unavailable.contains(key),
        !established.contains(key), !seenThisWindow.contains(key)
      else { continue }
      seenThisWindow.insert(key)

      let value = Double(truncating: transaction.spendMagnitude as NSDecimalNumber)
      guard value >= topDecile, value > 0 else { continue }

      insights.append(
        insight(
          for: transaction,
          normalizedPayee: key,
          topDecile: topDecile,
          historyWindowDays: historyWindowDays,
          context: context))
    }
    return insights
  }

  private static func unavailableExpensePayees(_ payees: [PayeeSummary]) -> Set<String> {
    Set(
      payees.lazy
        .filter { $0.isExpense && $0.hasUnavailableData }
        .map(\.normalizedPayee))
  }

  private static func repeatedExpensePayees(
    _ candidates: [InsightTransaction],
    context: InsightContext,
    windowDays: Int
  ) -> Set<String> {
    var transactionIdsByPayee: [String: Set<UUID>] = [:]
    for transaction in candidates where transaction.isExpense {
      let age = context.daysSince(transaction.date)
      guard age >= 0, age <= windowDays, !transaction.normalizedPayee.isEmpty else { continue }
      transactionIdsByPayee[transaction.normalizedPayee, default: []].insert(transaction.id)
    }
    return Set(
      transactionIdsByPayee.lazy
        .filter { $0.value.count > 1 }
        .map(\.key))
  }

  private static func insight(
    for transaction: InsightTransaction,
    normalizedPayee: String,
    topDecile: Double,
    historyWindowDays: Int,
    context: InsightContext
  ) -> Insight {
    Insight(
      id: "\(InsightKind.newMerchantAlert.rawValue):\(normalizedPayee)",
      kind: .newMerchantAlert,
      title: "First charge from \(payeeName(transaction))",
      date: transaction.date,
      framing: .neutral,
      actionability: .review,
      surprise: 0.5,
      monetaryImpact: transaction.amountInReportingCurrency(context),
      facts: [
        InsightFact("Merchant", payeeName(transaction)),
        InsightFact("Amount", context.formatted(transaction.amount)),
        InsightFact("Merchant history", "\(historyWindowDays) days"),
        InsightFact("Top-decile threshold", context.formatted(Decimal(-topDecile))),
      ],
      references: InsightReferences(
        accountIds: transaction.accountId.map { [$0] } ?? [],
        categoryIds: transaction.categoryId.map { [$0] } ?? [],
        transactionIds: [transaction.id],
        transactionFilter: transaction.evidenceFilter(calendar: context.calendar)))
  }

  private static func payeeName(_ transaction: InsightTransaction) -> String {
    transaction.rawPayee ?? "a new merchant"
  }
}
