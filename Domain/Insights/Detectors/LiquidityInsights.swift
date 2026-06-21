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
    guard let liquid = InsightAggregates.latestActual(dailyBalances)?.availableFunds,
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
        title: short
          ? "Only \(monthsText(months)) of runway left" : "\(monthsText(months)) of runway",
        date: context.now,
        framing: short ? .negative : .neutral,
        actionability: short ? .act : .review,
        surprise: short ? 0.7 : 0.35,
        monetaryImpact: InstrumentAmount(quantity: -burn, instrument: context.reportingCurrency),
        facts: [
          InsightFact("Available funds", context.formatted(liquid)),
          InsightFact("Monthly burn", context.formatted(burn)),
          InsightFact("Runway", monthsText(months)),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: balanceChart(dailyBalances, context: context))
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
    guard let liquid = InsightAggregates.latestActual(dailyBalances)?.availableFunds,
      liquid.quantity > 0,
      let spend = InsightAggregates.averageMonthlySpend(monthly, context: context),
      spend > 0
    else { return [] }

    let cushion = spend * multiple
    guard liquid.quantity > cushion else { return [] }
    let excess = liquid.quantity - cushion
    // Surface the buffer's basis — `multiple` months of average spending — so
    // the fact (and the narration built from it) explains the dollar figure
    // rather than asserting it bare.
    let bufferLabel = "Suggested buffer (\(multiple) months' spending)"

    return [
      Insight(
        id: "\(InsightKind.idleCashAlert.rawValue):\(monthKey(context))",
        kind: .idleCashAlert,
        title: "More cash than usual in liquid accounts",
        date: context.now,
        framing: .neutral,
        actionability: .act,
        surprise: 0.45,
        monetaryImpact: InstrumentAmount(quantity: excess, instrument: context.reportingCurrency),
        facts: [
          InsightFact("Available funds", context.formatted(liquid)),
          InsightFact("Average monthly spend", context.formatted(spend)),
          InsightFact(bufferLabel, context.formatted(cushion)),
          InsightFact("Idle excess", context.formatted(excess)),
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: balanceChart(dailyBalances, context: context))
    ]
  }

  /// Both liquidity insights tell a story about the same available-funds
  /// series — runway is that line sloping down, idle cash is it sitting high —
  /// so they share one chart, anchored at the latest actual reading the
  /// runway/cushion maths is computed from. The chart plots `availableFunds`
  /// (net of earmarks) to match the figures the facts now report. The
  /// fallback to `nil` (sparse data) is deliberately silent: a missing
  /// companion graph is a smaller row, not an error worth surfacing.
  private static func balanceChart(
    _ dailyBalances: [DailyBalance], context: InsightContext
  ) -> InsightChart? {
    InsightChartBuilders.balanceForecast(
      dailyBalances,
      reportingCurrency: context.reportingCurrency,
      highlight: InsightAggregates.latestActual(dailyBalances)?.date,
      value: \.availableFunds,
      seriesLabel: "Available funds")
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
