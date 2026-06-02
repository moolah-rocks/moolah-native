import Foundation

/// Investment insights (design §G): concentration risk (25), top / bottom
/// performer (26), and a deliberately conservative capital-gains
/// tax-harvest prompt (27). All operate on the per-instrument P&L that
/// `ReportingStore` already computes; amounts are in the reporting currency.
enum InvestmentInsights {
  static func detect(
    profitLoss: [InstrumentProfitLoss],
    capitalGains: [CapitalGainEvent],
    context: InsightContext,
    concentrationThreshold: Decimal = 0.4,
    minimumReturnFraction: Decimal = 0.1
  ) -> [Insight] {
    var insights: [Insight] = []
    if let concentration = concentrationRisk(
      profitLoss, threshold: concentrationThreshold, context: context)
    {
      insights.append(concentration)
    }
    insights.append(
      contentsOf: performers(profitLoss, minimumReturn: minimumReturnFraction, context: context))
    if let harvest = taxHarvest(profitLoss, capitalGains: capitalGains, context: context) {
      insights.append(harvest)
    }
    return insights
  }

  /// Single instrument exceeding `threshold` of total investable value (25).
  private static func concentrationRisk(
    _ profitLoss: [InstrumentProfitLoss], threshold: Decimal, context: InsightContext
  ) -> Insight? {
    let positive = profitLoss.filter { $0.currentValue > 0 }
    let total = positive.reduce(Decimal(0)) { $0 + $1.currentValue }
    guard total > 0, positive.count >= 2,
      let top = positive.max(by: { $0.currentValue < $1.currentValue })
    else { return nil }
    let share = top.currentValue / total
    guard share > threshold else { return nil }

    return Insight(
      id: "\(InsightKind.investmentConcentrationRisk.rawValue):\(top.instrument.id)",
      kind: .investmentConcentrationRisk,
      title: "\(top.instrument.displayLabel) is a big slice",
      detail:
        "\(top.instrument.displayLabel) makes up \(percent(share)) of your investments — "
        + "a concentrated position worth keeping an eye on.",
      date: context.now,
      framing: .neutral,
      actionability: .review,
      surprise: min(toDouble(share), 1),
      monetaryImpact: InstrumentAmount(
        quantity: top.currentValue, instrument: context.reportingCurrency),
      facts: [
        InsightFact("Holding", top.instrument.displayLabel),
        InsightFact("Value", context.formatted(top.currentValue)),
        InsightFact("Share of portfolio", percent(share)),
      ],
      references: InsightReferences(instrumentIds: [top.instrument.id]))
  }

  /// Best and worst unrealised performers over the holding period (26).
  private static func performers(
    _ profitLoss: [InstrumentProfitLoss], minimumReturn: Decimal, context: InsightContext
  ) -> [Insight] {
    let ranked =
      profitLoss
      .filter { $0.totalInvested > 0 && $0.currentValue > 0 }
      .sorted { $0.returnPercentage > $1.returnPercentage }
    guard ranked.count >= 2 else { return [] }
    var insights: [Insight] = []

    let minimumPercentage = minimumReturn * Decimal(100)
    if let top = ranked.first, top.returnPercentage >= minimumPercentage {
      insights.append(performerInsight(top, isTop: true, context: context))
    }
    if let bottom = ranked.last, bottom.returnPercentage <= -minimumPercentage {
      insights.append(performerInsight(bottom, isTop: false, context: context))
    }
    return insights
  }

  private static func performerInsight(
    _ position: InstrumentProfitLoss, isTop: Bool, context: InsightContext
  ) -> Insight {
    let kind: InsightKind = isTop ? .topPerformer : .bottomPerformer
    let label = position.instrument.displayLabel
    let returnText = percentFromPercentage(position.returnPercentage)
    return Insight(
      id: "\(kind.rawValue):\(position.instrument.id)",
      kind: kind,
      title: isTop ? "\(label) is your top performer" : "\(label) is lagging",
      detail:
        "\(label) is \(isTop ? "up" : "down") \(returnText) on your investment "
        + "(\(context.formatted(position.totalGain))).",
      date: context.now,
      framing: isTop ? .positive : .negative,
      actionability: isTop ? .informational : .review,
      surprise: min(toDouble(abs(position.returnPercentage)) / 100, 1),
      monetaryImpact: InstrumentAmount(
        quantity: position.totalGain, instrument: context.reportingCurrency),
      facts: [
        InsightFact("Holding", label),
        InsightFact("Return", returnText),
        InsightFact("Gain/loss", context.formatted(position.totalGain)),
        InsightFact("Invested", context.formatted(position.totalInvested)),
      ],
      references: InsightReferences(instrumentIds: [position.instrument.id]))
  }

  /// Conservative tax-loss-harvest prompt (27): when realised gains are
  /// positive for the period and unrealised losses exist, note that the
  /// losses could offset the gains. Framed as a prompt to review, never as
  /// tax advice — cross-jurisdiction correctness is out of scope (design
  /// §G-27 "effectively a compliance product").
  private static func taxHarvest(
    _ profitLoss: [InstrumentProfitLoss], capitalGains: [CapitalGainEvent], context: InsightContext
  ) -> Insight? {
    let realized = capitalGains.reduce(Decimal(0)) { $0 + $1.gain }
    guard realized > 0 else { return nil }
    let lossPositions = profitLoss.filter { $0.unrealizedGain < 0 }
    let unrealizedLoss = lossPositions.reduce(Decimal(0)) { $0 + $1.unrealizedGain }
    guard unrealizedLoss < 0, !lossPositions.isEmpty else { return nil }

    let offset = min(realized, -unrealizedLoss)
    let names = lossPositions.map(\.instrument.displayLabel).sorted().joined(separator: ", ")
    return Insight(
      id:
        "\(InsightKind.capitalGainsHarvest.rawValue):\(context.calendar.component(.year, from: context.now))",
      kind: .capitalGainsHarvest,
      title: "Possible tax-loss offset",
      detail:
        "You've realised \(context.formatted(realized)) in gains this period and hold "
        + "unrealised losses (\(names)). Realising some could offset up to "
        + "\(context.formatted(offset)) — worth reviewing with your tax situation.",
      date: context.now,
      framing: .neutral,
      actionability: .review,
      surprise: 0.4,
      monetaryImpact: InstrumentAmount(quantity: offset, instrument: context.reportingCurrency),
      facts: [
        InsightFact("Realised gains", context.formatted(realized)),
        InsightFact("Unrealised losses", context.formatted(unrealizedLoss)),
        InsightFact("Potential offset", context.formatted(offset)),
        InsightFact("Loss positions", names),
      ],
      references: InsightReferences(instrumentIds: lossPositions.map(\.instrument.id)))
  }

  private static func toDouble(_ value: Decimal) -> Double {
    Double(truncating: value as NSDecimalNumber)
  }

  private static func percent(_ fraction: Decimal) -> String {
    toDouble(fraction).formatted(.percent.precision(.fractionLength(0)))
  }

  private static func percentFromPercentage(_ percentage: Decimal) -> String {
    (toDouble(percentage) / 100).formatted(.percent.precision(.fractionLength(1)))
  }
}
