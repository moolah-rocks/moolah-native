import Foundation

/// Liquidity insights (design §D-17, §F-21): cash runway and idle-cash
/// alert. Both compare the user's current liquid balance against their
/// recent monthly burn / spend.
enum LiquidityInsights {
  /// Runway estimate (17): at the current net burn rate, how long liquid
  /// cash lasts. Only meaningful when the user is net-negative; a surplus
  /// month yields no runway insight (the savings-rate / projection
  /// detectors cover the healthy case).
  static func runway(
    dailyBalances: [DailyBalance],
    monthly: [MonthlyIncomeExpense],
    context: InsightContext,
    warnBelowMonths: Double = 6
  ) -> [Insight] {
    guard let liquid = InsightAggregates.latestActual(dailyBalances)?.balance,
      liquid.quantity > 0,
      let net = InsightAggregates.averageMonthlyNet(monthly, context: context),
      net < 0
    else { return [] }

    let burn = -net
    let burnDouble = Double(truncating: burn as NSDecimalNumber)
    guard burnDouble > 0 else { return [] }
    let months = Double(truncating: liquid.quantity as NSDecimalNumber) / burnDouble
    let short = months <= warnBelowMonths

    return [
      Insight(
        id: "\(InsightKind.runwayEstimate.rawValue):\(monthKey(context))",
        kind: .runwayEstimate,
        title: short ? "About \(monthsText(months)) of runway" : "\(monthsText(months)) of runway",
        detail:
          "You're spending about \(context.formatted(burn))/month more than you earn. "
          + "At that rate your \(context.formatted(liquid)) covers roughly \(monthsText(months)).",
        date: context.now,
        framing: short ? .negative : .neutral,
        actionability: short ? .act : .review,
        surprise: short ? 0.7 : 0.35,
        monetaryImpact: InstrumentAmount(quantity: -burn, instrument: context.reportingCurrency),
        facts: [
          InsightFact("Liquid cash", context.formatted(liquid)),
          InsightFact("Monthly burn", context.formatted(burn)),
          InsightFact("Runway", monthsText(months)),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  /// Idle-cash alert (21): liquid balance persistently far above the
  /// 30-day outflow — money that could be earning more elsewhere. Excess is
  /// `liquid − multiple × monthly spend`.
  static func idleCash(
    dailyBalances: [DailyBalance],
    monthly: [MonthlyIncomeExpense],
    context: InsightContext,
    multiple: Decimal = 3
  ) -> [Insight] {
    guard let liquid = InsightAggregates.latestActual(dailyBalances)?.balance,
      liquid.quantity > 0,
      let spend = InsightAggregates.averageMonthlySpend(monthly, context: context),
      spend > 0
    else { return [] }

    let cushion = spend * multiple
    guard liquid.quantity > cushion else { return [] }
    let excess = liquid.quantity - cushion

    return [
      Insight(
        id: "\(InsightKind.idleCashAlert.rawValue):\(monthKey(context))",
        kind: .idleCashAlert,
        title: "Spare cash sitting idle",
        detail:
          "You're holding \(context.formatted(liquid)) — about "
          + "\(context.formatted(excess)) more than the "
          + "\(context.formatted(cushion)) buffer your spending needs. It could be working harder.",
        date: context.now,
        framing: .neutral,
        actionability: .act,
        surprise: 0.45,
        monetaryImpact: InstrumentAmount(quantity: excess, instrument: context.reportingCurrency),
        facts: [
          InsightFact("Liquid cash", context.formatted(liquid)),
          InsightFact("Suggested buffer", context.formatted(cushion)),
          InsightFact("Idle excess", context.formatted(excess)),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]))
    ]
  }

  private static func monthsText(_ months: Double) -> String {
    if months >= 24 {
      return "\((months / 12).formatted(.number.precision(.fractionLength(1)))) years"
    }
    return "\(months.formatted(.number.precision(.fractionLength(0)))) months"
  }

  private static func monthKey(_ context: InsightContext) -> String {
    FinancialMonth.key(for: context.now, monthEnd: context.financialMonthEnd)
  }
}
