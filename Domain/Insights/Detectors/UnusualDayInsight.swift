import Foundation

/// Unusual day-of-week spend (design §B-9): the most recent day whose total
/// spend is a robust-z outlier against the distribution of same-weekday
/// daily totals ("you spent 3× your typical Sunday today").
enum UnusualDayInsight {
  static func detect(
    dailyTotals dailySummaries: [DailySpendSummary],
    context: InsightContext,
    windowDays: Int = 2,
    threshold: Double = 3,
    minimumRatio: Double = 2
  ) -> [Insight] {
    guard dailySummaries.count >= 14 else { return [] }

    // Daily spend magnitude per calendar day.
    var dailyTotals: [Date: Double] = [:]
    for summary in dailySummaries {
      let day = context.calendar.startOfDay(for: summary.day)
      dailyTotals[day, default: 0] += Double(
        truncating: summary.spendMagnitude as NSDecimalNumber)
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

    // Surface only the single most recent unusual day.
    for day in recentDays {
      let weekday = context.calendar.component(.weekday, from: day)
      guard let population = byWeekday[weekday], population.count >= 4 else { continue }
      let total = dailyTotals[day] ?? 0
      let typical = DescriptiveStatistics.median(population)
      guard typical > 0 else { continue }
      let zScore = DescriptiveStatistics.robustZScore(of: total, in: population)
      let ratio = total / typical
      guard zScore >= threshold, ratio >= minimumRatio else { continue }
      let spike = DaySpike(
        day: day, weekday: weekday, total: total, typical: typical, zScore: zScore)
      return [makeInsight(spike, context: context)]
    }
    return []
  }

  /// One day's outlier spend versus its weekday baseline.
  private struct DaySpike {
    let day: Date
    let weekday: Int
    let total: Double
    let typical: Double
    let zScore: Double
  }

  private static func makeInsight(_ spike: DaySpike, context: InsightContext) -> Insight {
    let day = spike.day
    let total = spike.total
    let typical = spike.typical
    let zScore = spike.zScore
    let weekdayName = weekdayName(spike.weekday, calendar: context.calendar)
    let ratio = typical > 0 ? total / typical : 0
    let multiple = ratio.formatted(.number.precision(.fractionLength(1)))
    let startOfDay = context.calendar.startOfDay(for: day).timeIntervalSince1970
    return Insight(
      id: "\(InsightKind.unusualDaySpend.rawValue):\(startOfDay)",
      kind: .unusualDaySpend,
      title: "Big spending \(weekdayName)",
      detail:
        "You spent \(context.formatted(Decimal(-total))) — about "
        + "\(multiple)× a typical \(weekdayName) (\(context.formatted(Decimal(-typical)))).",
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
        InsightFact("Multiple", "\(multiple)×"),
      ],
      references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
  }

  private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
    let symbols = calendar.weekdaySymbols
    let index = weekday - 1
    guard symbols.indices.contains(index) else { return "day" }
    return symbols[index]
  }
}
