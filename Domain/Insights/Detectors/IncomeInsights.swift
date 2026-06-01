import Foundation

/// Income-analysis insights (design §H), built on the same subscription
/// clustering applied to positive-amount streams: paycheck timing (14),
/// income stability score (29), and missing-paycheck alert (30).
///
/// The caller passes the already-detected income streams
/// (`SubscriptionDetector.detect(incomeStreams: true)`) so the clustering
/// runs once and is shared with any other income consumer.
enum IncomeInsights {
  static func detect(
    incomeStreams: [DetectedSubscription],
    context: InsightContext,
    missedGraceDays: Int = 3
  ) -> [Insight] {
    guard let primary = incomeStreams.max(by: { $0.monthlyCostMagnitude < $1.monthlyCostMagnitude })
    else { return [] }

    var insights: [Insight] = []
    if let missing = missingPaycheck(primary, context: context, grace: missedGraceDays) {
      insights.append(missing)
    } else if let timing = paycheckTiming(primary, context: context) {
      insights.append(timing)
    }
    if let stability = stabilityScore(primary, context: context) {
      insights.append(stability)
    }
    return insights
  }

  /// Project the next paycheck date and amount (14).
  private static func paycheckTiming(
    _ stream: DetectedSubscription, context: InsightContext
  ) -> Insight? {
    guard let next = stream.nextExpectedDate(calendar: context.calendar),
      context.daysUntil(next) >= 0
    else { return nil }
    let dateText = next.formatted(.dateTime.month(.abbreviated).day())
    return Insight(
      id: "\(InsightKind.paycheckTimingPattern.rawValue):\(stream.id)",
      kind: .paycheckTimingPattern,
      title: "Next pay around \(dateText)",
      detail:
        "Your \(stream.period.displayName) income from \(stream.displayPayee) "
        + "(about \(context.formatted(stream.medianAmount))) is next expected around \(dateText).",
      date: context.now,
      framing: .neutral,
      actionability: .informational,
      surprise: 0.15,
      monetaryImpact: InstrumentAmount(
        quantity: stream.medianAmount, instrument: context.reportingCurrency),
      facts: [
        InsightFact("Source", stream.displayPayee),
        InsightFact("Typical amount", context.formatted(stream.medianAmount)),
        InsightFact("Cadence", stream.period.displayName),
        InsightFact("Next expected", dateText),
      ],
      references: InsightReferences(
        accountIds: stream.accountId.map { [$0] } ?? []))
  }

  /// Income stability score (29): lower amount variation → higher score.
  private static func stabilityScore(
    _ stream: DetectedSubscription, context: InsightContext
  ) -> Insight? {
    guard stream.amounts.count >= 3 else { return nil }
    let magnitudes = stream.amounts.map {
      Double(truncating: ($0 < 0 ? -$0 : $0) as NSDecimalNumber)
    }
    guard let variation = DescriptiveStatistics.coefficientOfVariation(magnitudes) else {
      return nil
    }
    let score = max(0, min(1, 1 - variation))
    let descriptor: String
    switch score {
    case 0.85...: descriptor = "very steady"
    case 0.6..<0.85: descriptor = "fairly steady"
    default: descriptor = "variable"
    }
    return Insight(
      id: "\(InsightKind.incomeStabilityScore.rawValue):\(stream.id)",
      kind: .incomeStabilityScore,
      title: "Your income is \(descriptor)",
      detail:
        "Your \(stream.displayPayee) income varies by about \(percent(variation)) "
        + "pay to pay — \(descriptor).",
      date: context.now,
      framing: score >= 0.6 ? .positive : .neutral,
      actionability: .informational,
      surprise: 0.2,
      monetaryImpact: nil,
      facts: [
        InsightFact("Source", stream.displayPayee),
        InsightFact(
          "Stability", "\((score * 100).formatted(.number.precision(.fractionLength(0))))/100"),
        InsightFact("Variation", percent(variation)),
      ],
      references: InsightReferences(
        accountIds: stream.accountId.map { [$0] } ?? []))
  }

  /// Missing-paycheck alert (30): expected pay overdue past the grace window.
  private static func missingPaycheck(
    _ stream: DetectedSubscription, context: InsightContext, grace: Int
  ) -> Insight? {
    guard let next = stream.nextExpectedDate(calendar: context.calendar) else { return nil }
    let overdue = context.daysSince(next)
    guard overdue > grace else { return nil }
    let expectedText = next.formatted(.dateTime.month(.abbreviated).day())
    return Insight(
      id: "\(InsightKind.missingPaycheckAlert.rawValue):\(stream.id)",
      kind: .missingPaycheckAlert,
      title: "Expected pay hasn't arrived",
      detail:
        "Your \(stream.displayPayee) income (about \(context.formatted(stream.medianAmount))) "
        + "was expected around \(expectedText) but hasn't shown up in \(overdue) days.",
      date: context.now,
      framing: .negative,
      actionability: .act,
      surprise: 0.65,
      monetaryImpact: InstrumentAmount(
        quantity: stream.medianAmount, instrument: context.reportingCurrency),
      facts: [
        InsightFact("Source", stream.displayPayee),
        InsightFact("Expected", expectedText),
        InsightFact("Days overdue", "\(overdue)"),
        InsightFact("Typical amount", context.formatted(stream.medianAmount)),
      ],
      references: InsightReferences(
        accountIds: stream.accountId.map { [$0] } ?? []))
  }

  private static func percent(_ fraction: Double) -> String {
    max(fraction, 0).formatted(.percent.precision(.fractionLength(0)))
  }
}
