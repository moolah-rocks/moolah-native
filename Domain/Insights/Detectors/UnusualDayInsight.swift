import Foundation

/// Unusual day-of-week spend (design §B-9): the most recent day whose total
/// spend is a robust-z outlier against the distribution of same-weekday
/// daily totals ("you spent 3× your typical Sunday today").
enum UnusualDayInsight {
  static func detect(
    transactions: [InsightTransaction],
    context: InsightContext,
    windowDays: Int = 2,
    threshold: Double = 3,
    minimumRatio: Double = 2
  ) -> [Insight] {
    let expenses = transactions.filter(\.isExpense)
    guard expenses.count >= 14 else { return [] }

    // Daily spend magnitude per calendar day.
    var dailyTotals: [Date: Double] = [:]
    for transaction in expenses {
      let day = context.calendar.startOfDay(for: transaction.date)
      dailyTotals[day, default: 0] += Double(truncating: transaction.spendMagnitude as NSDecimalNumber)
    }
    guard !dailyTotals.isEmpty else { return [] }

    // Group day totals by weekday.
    var byWeekday: [Int: [Double]] = [:]
    for (day, total) in dailyTotals {
      let weekday = context.calendar.component(.weekday, from: day)
      byWeekday[weekday, default: []].append(total)
    }

    // Examine the most recent day(s) in the window.
    let recentDays = dailyTotals.keys
      .filter { context.daysSince($0) >= 0 && context.daysSince($0) <= windowDays }
      .sorted(by: >)

    var insights: [Insight] = []
    for day in recentDays {
      let weekday = context.calendar.component(.weekday, from: day)
      guard let population = byWeekday[weekday], population.count >= 4 else { continue }
      let total = dailyTotals[day] ?? 0
      let typical = DescriptiveStatistics.median(population)
      guard typical > 0 else { continue }
      let zScore = DescriptiveStatistics.robustZScore(of: total, in: population)
      let ratio = total / typical
      guard zScore >= threshold, ratio >= minimumRatio else { continue }

      let weekdayName = weekdayName(weekday, calendar: context.calendar)
      insights.append(
        Insight(
          id: "\(InsightKind.unusualDaySpend.rawValue):\(context.calendar.startOfDay(for: day).timeIntervalSince1970)",
          kind: .unusualDaySpend,
          title: "Big spending \(weekdayName)",
          detail:
            "You spent \(context.formatted(Decimal(-total))) — about "
            + "\(ratio.formatted(.number.precision(.fractionLength(1))))× a typical "
            + "\(weekdayName) (\(context.formatted(Decimal(-typical)))).",
          date: day,
          framing: .neutral,
          actionability: .informational,
          surprise: NormalDistribution.surprise(fromZScore: zScore),
          monetaryImpact: InstrumentAmount(
            quantity: Decimal(-total), instrument: context.reportingCurrency),
          facts: [
            InsightFact("Day", weekdayName),
            InsightFact("Spent", context.formatted(Decimal(-total))),
            InsightFact("Typical \(weekdayName)", context.formatted(Decimal(-typical))),
            InsightFact("Multiple", "\(ratio.formatted(.number.precision(.fractionLength(1))))×"),
          ],
          references: InsightReferences(instrumentIds: [context.reportingCurrency.id])))
      break  // Surface only the single most recent unusual day.
    }
    return insights
  }

  private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
    let symbols = calendar.weekdaySymbols
    let index = weekday - 1
    guard symbols.indices.contains(index) else { return "day" }
    return symbols[index]
  }
}
