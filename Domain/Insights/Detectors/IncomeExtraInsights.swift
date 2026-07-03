import Foundation

/// Income extensions (research follow-up §E-2, §E-3): a one-off windfall and
/// a sustained pay-rate change. Both mirror existing expense techniques onto
/// the income side, which the original catalog only ever analysed for spend.
enum IncomeExtraInsights {
  /// Windfall / one-off income alert (E-3): an income deposit that is a
  /// robust-z outlier above *its own source's* typical inflow. Positive
  /// framing — the income-side counterpart of the large-transaction anomaly.
  ///
  /// The baseline is scoped per source (normalized payee), mirroring the
  /// per-category baseline `LargeTransactionInsight` uses. Scoring a deposit
  /// against the median of *every* income stream pooled together would flag a
  /// regular salary as a windfall (a large but perfectly normal deposit is an
  /// outlier against the global income median) and, worse, print that global
  /// median as the named source's "typical" income — a figure unrelated to
  /// the source in the message. A source with fewer than
  /// `minimumSourceSamples` deposits is skipped: with too little history there
  /// is no basis to call a deposit unusual *for that source*, and a
  /// first-ever large deposit from a brand-new source has no baseline to
  /// compare against (the same trade-off the large-transaction detector makes
  /// for sparse categories).
  static func windfall(
    recentCandidates: [InsightTransaction],
    incomeSourceSamples: [IncomeSourceSamples],
    context: InsightContext,
    windowDays: Int = 30,
    threshold: Double = 3.5,
    minimumSourceSamples: Int = 6
  ) -> [Insight] {
    let samplesBySource = Dictionary(
      incomeSourceSamples.map { source in
        (
          source.normalizedPayee,
          source.magnitudes.map { Double(truncating: $0 as NSDecimalNumber) }
        )
      },
      uniquingKeysWith: { first, _ in first })

    var best: InsightTransaction?
    var bestScore = threshold
    var bestPopulation: [Double] = []
    for transaction in recentCandidates.filter(\.isIncome) {
      let age = context.daysSince(transaction.date)
      guard age >= 0, age <= windowDays else { continue }
      // Only fire when the source itself has enough history to establish a
      // stable typical deposit; otherwise the "typical income" baseline would
      // be meaningless (see the type doc).
      let population = samplesBySource[transaction.normalizedPayee] ?? []
      guard population.count >= minimumSourceSamples else { continue }
      let value = Double(truncating: transaction.incomeMagnitude as NSDecimalNumber)
      let zScore = DescriptiveStatistics.robustZScore(of: value, in: population)
      if zScore >= bestScore {
        bestScore = zScore
        best = transaction
        bestPopulation = population
      }
    }
    guard let windfall = best else { return [] }

    let typical = DescriptiveStatistics.median(bestPopulation)
    return [
      Insight(
        id: "\(InsightKind.windfallIncome.rawValue):\(windfall.id.uuidString)",
        kind: .windfallIncome,
        title: "Larger-than-usual deposit",
        date: windfall.date,
        framing: .positive,
        actionability: .informational,
        surprise: NormalDistribution.surprise(fromZScore: bestScore),
        monetaryImpact: windfall.amountInReportingCurrency(context),
        facts: [
          InsightFact("Source", payee(windfall)),
          InsightFact("Amount", context.formatted(windfall.amount)),
          InsightFact("Typical income", context.formatted(Decimal(typical))),
        ],
        references: InsightReferences(
          accountIds: windfall.accountId.map { [$0] } ?? [],
          transactionIds: [windfall.id]))
    ]
  }

  /// Pay-rate change (E-2): the latest recurring-income amount differs from
  /// the stream's prior median by more than `threshold`. A rise is framed
  /// positively (pay rise), a fall negatively (pay cut).
  static func payRateChange(
    incomeStreams: [DetectedSubscription],
    context: InsightContext,
    threshold: Double = 0.05
  ) -> [Insight] {
    guard
      let stream = incomeStreams.max(by: { $0.monthlyCostMagnitude < $1.monthlyCostMagnitude }),
      stream.amounts.count >= 3
    else { return [] }
    let priorMedian = DescriptiveStatistics.median(stream.amounts.dropLast().map(magnitude))
    let latest = magnitude(stream.latestAmount)
    guard priorMedian > 0 else { return [] }
    let change = (latest - priorMedian) / priorMedian
    guard abs(change) > threshold else { return [] }

    let increased = change > 0
    return [
      Insight(
        id: "\(InsightKind.payRateChange.rawValue):\(stream.id)",
        kind: .payRateChange,
        title: increased ? "Your pay went up" : "Your pay dropped",
        date: stream.lastDate,
        framing: increased ? .positive : .negative,
        actionability: .informational,
        surprise: min(abs(change) * 2, 1),
        monetaryImpact: InstrumentAmount(
          quantity: Decimal(latest - priorMedian), instrument: context.reportingCurrency),
        facts: [
          InsightFact("Source", stream.displayPayee),
          InsightFact("New amount", context.formatted(stream.latestAmount)),
          InsightFact("Previous", context.formatted(Decimal(priorMedian))),
          InsightFact("Change", "\(increased ? "+" : "−")\(percent(abs(change)))"),
        ],
        references: InsightReferences(accountIds: stream.accountId.map { [$0] } ?? []),
        chart: stream.chargeChart(reportingCurrency: context.reportingCurrency))
    ]
  }

  private static func magnitude(_ value: Decimal) -> Double {
    Double(truncating: (value < 0 ? -value : value) as NSDecimalNumber)
  }

  private static func payee(_ transaction: InsightTransaction) -> String {
    transaction.rawPayee ?? "an unknown source"
  }

  private static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }
}
