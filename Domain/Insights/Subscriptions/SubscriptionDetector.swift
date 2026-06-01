import Foundation

/// Clusters transactions into recurring payment / income streams (design
/// §A-1). Pure and deterministic: groups by normalised payee + direction,
/// then within each group inspects the inter-arrival gaps and the amount
/// stability to decide whether the stream is a subscription.
///
/// References: Plaid's recurring-stream approach and BBVA's weighted
/// DBSCAN, simplified to a histogram-free median-gap test that's adequate
/// for a single user's sparse history (design §A-1).
enum SubscriptionDetector {
  /// Tuning knobs, exposed so tests can tighten / loosen the gates without
  /// editing the detector.
  struct Parameters: Sendable {
    /// Minimum occurrences before a stream is "confirmed".
    var minimumOccurrences: Int = 3
    /// Maximum coefficient of variation of the amount magnitudes. The
    /// design cites 5–10%; 12% absorbs small FX / rounding wobble.
    var maximumAmountVariation: Double = 0.12
    /// Relative tolerance when snapping the median gap to a nominal period.
    var periodTolerance: Double = 0.25
    /// Maximum coefficient of variation of the inter-arrival gaps. Rejects
    /// streams whose timing is too erratic to be a subscription.
    var maximumIntervalVariation: Double = 0.35
  }

  /// Detect subscription streams among `transactions`. Pass `incomeStreams:
  /// true` to detect recurring income (paychecks) instead of expenses —
  /// the same algorithm runs over the opposite sign.
  static func detect(
    in transactions: [InsightTransaction],
    incomeStreams: Bool = false,
    parameters: Parameters = Parameters(),
    calendar: Calendar
  ) -> [DetectedSubscription] {
    let relevant = transactions.filter {
      incomeStreams ? $0.isIncome : $0.isExpense
    }
    let groups = Dictionary(grouping: relevant) { $0.normalizedPayee }

    var detected: [DetectedSubscription] = []
    for (payee, records) in groups where !payee.isEmpty {
      guard
        let subscription = evaluate(
          payee: payee,
          records: records,
          incomeStreams: incomeStreams,
          parameters: parameters,
          calendar: calendar)
      else { continue }
      detected.append(subscription)
    }
    return detected.sorted { $0.monthlyCostMagnitude > $1.monthlyCostMagnitude }
  }

  /// Evaluate one payee's records against the cadence + amount gates.
  private static func evaluate(
    payee: String,
    records: [InsightTransaction],
    incomeStreams: Bool,
    parameters: Parameters,
    calendar: Calendar
  ) -> DetectedSubscription? {
    let sorted = records.sorted { $0.date < $1.date }
    guard sorted.count >= parameters.minimumOccurrences else { return nil }

    let intervals = consecutiveDayGaps(of: sorted.map(\.date), calendar: calendar)
    guard !intervals.isEmpty else { return nil }
    let medianInterval = DescriptiveStatistics.median(intervals)
    guard medianInterval > 0 else { return nil }

    if let intervalCV = DescriptiveStatistics.coefficientOfVariation(intervals),
      intervalCV > parameters.maximumIntervalVariation
    {
      return nil
    }

    guard
      let period = SubscriptionPeriod.nearest(
        toIntervalDays: medianInterval, tolerance: parameters.periodTolerance)
    else { return nil }

    let amounts = sorted.map(\.amount)
    let magnitudes = amounts.map { Double(truncating: ($0 < 0 ? -$0 : $0) as NSDecimalNumber) }
    if let amountCV = DescriptiveStatistics.coefficientOfVariation(magnitudes),
      amountCV > parameters.maximumAmountVariation
    {
      return nil
    }

    let medianMagnitude = DescriptiveStatistics.median(magnitudes)
    let medianAmount = Decimal(medianMagnitude * (incomeStreams ? 1.0 : -1.0))
    let maturedIndex = parameters.minimumOccurrences - 1
    let dominantAccount = mostCommonAccount(in: sorted)

    return DetectedSubscription(
      id: "\(incomeStreams ? "income" : "expense"):\(payee)",
      normalizedPayee: payee,
      displayPayee: sorted.last?.rawPayee ?? payee,
      categoryId: mostCommonCategory(in: sorted),
      accountId: dominantAccount,
      period: period,
      occurrenceCount: sorted.count,
      firstDate: sorted.first?.date ?? sorted[0].date,
      lastDate: sorted.last?.date ?? sorted[0].date,
      maturedDate: sorted[min(maturedIndex, sorted.count - 1)].date,
      medianIntervalDays: medianInterval,
      medianAmount: medianAmount,
      latestAmount: amounts.last ?? medianAmount,
      amounts: amounts,
      isIncome: incomeStreams)
  }

  private static func consecutiveDayGaps(of dates: [Date], calendar: Calendar) -> [Double] {
    guard dates.count > 1 else { return [] }
    var gaps: [Double] = []
    gaps.reserveCapacity(dates.count - 1)
    for index in 1..<dates.count {
      let days = calendar.dateComponents([.day], from: dates[index - 1], to: dates[index]).day ?? 0
      gaps.append(Double(days))
    }
    return gaps
  }

  private static func mostCommonCategory(in records: [InsightTransaction]) -> UUID? {
    let categorized = records.compactMap(\.categoryId)
    guard !categorized.isEmpty else { return nil }
    return Dictionary(grouping: categorized, by: { $0 })
      .max { $0.value.count < $1.value.count }?
      .key
  }

  private static func mostCommonAccount(in records: [InsightTransaction]) -> UUID? {
    let accounts = records.compactMap(\.accountId)
    guard !accounts.isEmpty else { return nil }
    return Dictionary(grouping: accounts, by: { $0 })
      .max { $0.value.count < $1.value.count }?
      .key
  }
}
