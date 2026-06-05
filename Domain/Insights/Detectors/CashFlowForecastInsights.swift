import Foundation

/// Forecast-driven cash-flow insights (design §D): upcoming-bill cash
/// warning (13) and projected month-end balance (15). Both read the
/// forecast tail of the daily-balance series that `AnalysisStore` already
/// projects from scheduled transactions — the insight layer adds no
/// independent forecasting, it interprets the existing one.
enum CashFlowForecastInsights {
  /// Flag when the projected current-funds balance dips below `buffer`
  /// within the horizon — the user is heading for a shortfall, optionally
  /// attributable to a known upcoming bill.
  static func upcomingBillWarning(
    dailyBalances: [DailyBalance],
    scheduledBills: [ScheduledBill],
    context: InsightContext,
    horizonDays: Int = 35,
    buffer: InstrumentAmount? = nil
  ) -> [Insight] {
    let bufferQuantity = buffer?.quantity ?? 0
    let forecast =
      dailyBalances
      .filter {
        $0.isForecast && context.daysUntil($0.date) >= 0
          && context.daysUntil($0.date) <= horizonDays
      }
      .sorted { $0.date < $1.date }
    guard let trough = forecast.min(by: { $0.balance.quantity < $1.balance.quantity }) else {
      return []
    }
    guard trough.balance.quantity < bufferQuantity else { return [] }

    let culprit =
      scheduledBills
      .filter {
        context.daysUntil($0.date) >= 0 && $0.date <= trough.date && $0.amount.quantity < 0
      }
      .min { $0.amount.quantity < $1.amount.quantity }
    let shortfall = bufferQuantity - trough.balance.quantity
    let dateText = trough.date.formatted(.dateTime.month(.abbreviated).day())

    var facts: [InsightFact] = [
      InsightFact("Lowest projected", context.formatted(trough.balance)),
      InsightFact("On", dateText),
    ]
    if buffer != nil {
      facts.append(InsightFact("Buffer", context.formatted(bufferQuantity)))
    }
    if let culprit, let payee = culprit.payee {
      facts.append(InsightFact("Upcoming bill", "\(payee) \(context.formatted(culprit.amount))"))
    }

    return [
      Insight(
        id: "\(InsightKind.upcomingBillWarning.rawValue):\(trough.date.timeIntervalSince1970)",
        kind: .upcomingBillWarning,
        title: "Low balance coming up",
        date: context.now,
        framing: .negative,
        actionability: .act,
        surprise: 0.8,
        monetaryImpact: InstrumentAmount(
          quantity: -shortfall, instrument: context.reportingCurrency),
        facts: facts,
        references: InsightReferences(
          accountIds: culprit?.accountId.map { [$0] } ?? [],
          instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.balanceForecast(
          dailyBalances, reportingCurrency: context.reportingCurrency, highlight: trough.date))
    ]
  }

  /// Projected end-of-current-financial-month balance with a confidence
  /// band from recent daily-change volatility (design §D-15). Informational
  /// and positive-leaning — a forward-looking "here's where you'll land".
  static func projectedMonthEnd(
    dailyBalances: [DailyBalance],
    context: InsightContext
  ) -> [Insight] {
    let forecast = dailyBalances.filter(\.isForecast).sorted { $0.date < $1.date }
    guard !forecast.isEmpty else { return [] }
    let currentBucket = FinancialMonth.key(
      for: context.now, monthEnd: context.financialMonthEnd)
    let withinMonth = forecast.filter {
      FinancialMonth.key(for: $0.date, monthEnd: context.financialMonthEnd) == currentBucket
    }
    guard let monthEndDay = withinMonth.last ?? forecast.first else { return [] }

    let band = confidenceBand(dailyBalances: dailyBalances)
    let projected = monthEndDay.balance.quantity

    let projectedMagnitude = abs(Double(truncating: projected as NSDecimalNumber))
    let bandMagnitude = abs(Double(truncating: band as NSDecimalNumber))
    // A projection whose 14-day noise band is at least half its own size carries
    // no usable signal — suppress it rather than print a scary ±range.
    guard projectedMagnitude == 0 || bandMagnitude < Self.maxBandFraction * projectedMagnitude
    else {
      return []
    }

    let rounded = context.formattedApproximate(projected)
    return [
      Insight(
        id: "\(InsightKind.projectedMonthEndBalance.rawValue):\(currentBucket)",
        kind: .projectedMonthEndBalance,
        title: "On track to end the month around \(rounded)",
        date: monthEndDay.date,
        framing: projected >= 0 ? .positive : .negative,
        actionability: .informational,
        surprise: 0.2,
        // No `monetaryImpact`: the rounded projection is already in the headline
        // ("around $225,000"). An exact `$225,460.22` impact badge would
        // contradict the deliberately-rounded headline, so it is omitted.
        facts: [
          InsightFact("Projected balance", rounded)
        ],
        references: InsightReferences(instrumentIds: [context.reportingCurrency.id]),
        chart: InsightChartBuilders.balanceForecast(
          dailyBalances, reportingCurrency: context.reportingCurrency, highlight: monthEndDay.date))
    ]
  }

  /// A projection whose noise band reaches this fraction of its own magnitude
  /// is treated as signalless and suppressed.
  private static let maxBandFraction = 0.5

  /// Standard deviation of day-over-day balance changes in the historical
  /// tail, used as a ± band. Falls back to zero when too little history.
  private static func confidenceBand(dailyBalances: [DailyBalance]) -> Decimal {
    let actual = dailyBalances.filter { !$0.isForecast }.sorted { $0.date < $1.date }
    guard actual.count >= 3 else { return 0 }
    var deltas: [Double] = []
    for index in 1..<actual.count {
      let change = actual[index].balance.quantity - actual[index - 1].balance.quantity
      deltas.append(Double(truncating: change as NSDecimalNumber))
    }
    let deviation = DescriptiveStatistics.standardDeviation(deltas)
    // Roughly two weeks of accumulated daily noise as the band.
    return Decimal(deviation * 14.0.squareRoot())
  }
}
