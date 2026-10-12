import Foundation

/// Net-worth milestone (design §G-24): net worth crossing a round-number
/// threshold since the comparison point. Positive-framed by design — one of
/// the guaranteed feel-good insights.
enum NetWorthInsights {
  static func detect(
    dailyBalances: [DailyBalance],
    context: InsightContext,
    lookbackDays: Int = 35
  ) -> [Insight] {
    let actual = dailyBalances.filter { !$0.isForecast }.sorted { $0.date < $1.date }
    guard let latest = actual.last else { return [] }
    let current = latest.netWorth.quantity

    let baseline =
      actual.last { context.daysSince($0.date) >= lookbackDays } ?? actual.first
    guard let baseline, current > baseline.netWorth.quantity, current > 0 else { return [] }

    let step = milestoneStep(for: current)
    guard step > 0 else { return [] }
    let crossed = highestMultiple(of: step, atOrBelow: current)
    guard crossed > baseline.netWorth.quantity, crossed > 0,
      let lastBelow = actual.lastIndex(where: { $0.netWorth.quantity < crossed }),
      let crossing = actual.dropFirst(lastBelow + 1).first
    else { return [] }

    return [
      Insight(
        id: "\(InsightKind.netWorthMilestone.rawValue):\(decimalKey(crossed))",
        kind: .netWorthMilestone,
        title: "Net worth passed \(context.formatted(crossed))",
        date: crossing.date,
        framing: .positive,
        actionability: .informational,
        surprise: 0.5,
        monetaryImpact: latest.netWorth - baseline.netWorth,
        facts: [
          InsightFact("Net worth", context.formatted(current)),
          InsightFact("Milestone", context.formatted(crossed)),
          InsightFact("Was", context.formatted(baseline.netWorth)),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.netWorthTrend(
          dailyBalances, reportingCurrency: context.reportingCurrency))
    ]
  }

  /// Milestone granularity scales with magnitude so a $5k net worth gets
  /// $1k steps and a $5M net worth gets $100k steps.
  private static func milestoneStep(for value: Decimal) -> Decimal {
    let magnitude = Double(truncating: value as NSDecimalNumber)
    switch magnitude {
    case ..<10_000: return 1_000
    case ..<100_000: return 10_000
    case ..<1_000_000: return 25_000
    default: return 100_000
    }
  }

  private static func highestMultiple(of step: Decimal, atOrBelow value: Decimal) -> Decimal {
    guard step > 0 else { return 0 }
    let quotient = (value / step) as NSDecimalNumber
    let floored = floor(quotient.doubleValue)
    return step * Decimal(floored)
  }

  private static func decimalKey(_ value: Decimal) -> String {
    "\(NSDecimalNumber(decimal: value).int64Value)"
  }
}
