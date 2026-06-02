import Foundation

/// Spend-habit insights (research follow-up §F-1, §E-4): a lapsed merchant
/// you used to pay regularly, and a habitual weekend-vs-weekday spend skew.
enum SpendHabitInsights {
  /// Lapsed merchant (F-1): a payee you paid regularly but haven't in a
  /// while — a broader cancellation signal than the subscription-cadence
  /// proxy. Surfaces the highest-spend lapsed merchant.
  static func lapsedMerchant(
    payees: [PayeeSummary],
    context: InsightContext,
    minimumOccurrences: Int = 4,
    minimumSilentDays: Int = 90
  ) -> [Insight] {
    var best: Insight?
    var bestSpend = 0.0
    for payee in payees
    where payee.isExpense && !payee.normalizedPayee.isEmpty
      && payee.occurrenceCount >= minimumOccurrences
    {
      let silentDays = context.daysSince(payee.lastSeen)
      let medianInterval = medianIntervalDays(
        of: payee.occurrences.map(\.date), calendar: context.calendar)
      guard medianInterval > 0,
        Double(silentDays) > max(Double(minimumSilentDays), 3 * medianInterval)
      else { continue }
      let windowedMagnitude =
        payee.windowedTotal.quantity < 0 ? -payee.windowedTotal.quantity : 0
      let totalSpend = Double(truncating: windowedMagnitude as NSDecimalNumber)
      if totalSpend > bestSpend {
        bestSpend = totalSpend
        best = makeLapsedInsight(payee: payee, silentDays: silentDays, context: context)
      }
    }
    return best.map { [$0] } ?? []
  }

  /// Weekend-vs-weekday spend skew (E-4): the ratio of average daily
  /// weekend spend to weekday spend, when stable and lopsided.
  static func weekendSkew(
    dailyTotals dailySummaries: [DailySpendSummary],
    context: InsightContext,
    minimumDaysEachSide: Int = 8,
    minimumRatio: Double = 1.5
  ) -> [Insight] {
    var weekendTotals: [Double] = []
    var weekdayTotals: [Double] = []
    let byDay = dailyTotals(of: dailySummaries, context: context)
    for (day, total) in byDay {
      let weekday = context.calendar.component(.weekday, from: day)
      if weekday == 1 || weekday == 7 {
        weekendTotals.append(total)
      } else {
        weekdayTotals.append(total)
      }
    }
    guard weekendTotals.count >= minimumDaysEachSide,
      weekdayTotals.count >= minimumDaysEachSide
    else { return [] }
    let weekendMean = DescriptiveStatistics.mean(weekendTotals)
    let weekdayMean = DescriptiveStatistics.mean(weekdayTotals)
    guard weekdayMean > 0 else { return [] }
    let ratio = weekendMean / weekdayMean
    guard ratio >= minimumRatio else { return [] }

    return [
      Insight(
        id: "\(InsightKind.weekendSpendSkew.rawValue):\(monthKey(context))",
        kind: .weekendSpendSkew,
        title: "Weekends are your big spend days",
        detail:
          "You spend about \(multiple(ratio))× as much per day on weekends "
          + "(\(context.formatted(Decimal(-weekendMean)))) as on weekdays "
          + "(\(context.formatted(Decimal(-weekdayMean)))).",
        date: context.now,
        framing: .neutral,
        actionability: .informational,
        surprise: min((ratio - 1) / 2, 1),
        monetaryImpact: nil,
        facts: [
          InsightFact("Avg weekend day", context.formatted(Decimal(-weekendMean))),
          InsightFact("Avg weekday", context.formatted(Decimal(-weekdayMean))),
          InsightFact("Ratio", "\(multiple(ratio))×"),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  // MARK: - Helpers

  private static func makeLapsedInsight(
    payee: PayeeSummary, silentDays: Int, context: InsightContext
  ) -> Insight {
    let name = payee.displayPayee
    let last = payee.occurrences.last
    return Insight(
      id: "\(InsightKind.lapsedMerchant.rawValue):\(payee.normalizedPayee)",
      kind: .lapsedMerchant,
      title: "You've stopped paying \(name)",
      detail:
        "You used to pay \(name) regularly but haven't in \(silentDays) days. "
        + "If you've moved on, there's nothing to do — otherwise worth a check.",
      date: payee.lastSeen,
      framing: .neutral,
      actionability: .review,
      surprise: 0.35,
      monetaryImpact: nil,
      facts: [
        InsightFact("Merchant", name),
        InsightFact("Days since last", "\(silentDays)"),
      ],
      references: InsightReferences(
        accountIds: last?.accountId.map { [$0] } ?? [],
        categoryIds: last?.categoryId.map { [$0] } ?? []))
  }

  private static func dailyTotals(
    of dailySummaries: [DailySpendSummary], context: InsightContext
  ) -> [Date: Double] {
    var totals: [Date: Double] = [:]
    for summary in dailySummaries {
      let day = context.calendar.startOfDay(for: summary.day)
      totals[day, default: 0] += Double(truncating: summary.spendMagnitude as NSDecimalNumber)
    }
    return totals
  }

  private static func medianIntervalDays(of dates: [Date], calendar: Calendar) -> Double {
    guard dates.count > 1 else { return 0 }
    var gaps: [Double] = []
    for index in 1..<dates.count {
      let days = calendar.dateComponents([.day], from: dates[index - 1], to: dates[index]).day ?? 0
      gaps.append(Double(days))
    }
    return DescriptiveStatistics.median(gaps)
  }

  private static func multiple(_ ratio: Double) -> String {
    ratio.formatted(.number.precision(.fractionLength(1)))
  }

  private static func monthKey(_ context: InsightContext) -> String {
    FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd)
  }
}
