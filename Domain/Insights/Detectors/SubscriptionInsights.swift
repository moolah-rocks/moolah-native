import Foundation

/// Turns detected subscription streams (`SubscriptionDetector`) into the
/// recurring-management insights: new-recurring (5), price-hike (2),
/// duplicate (3), and cancellation-candidate (4). Subscription *overspend*
/// (23) lives in `SavingsOpportunityInsights` because it needs income.
enum SubscriptionInsights {
  /// A stream that reached its third occurrence within the last `window`
  /// days — it just became a confirmed subscription (design §A-5).
  static func newRecurring(
    _ subscriptions: [DetectedSubscription], context: InsightContext, windowDays: Int = 7
  ) -> [Insight] {
    subscriptions.compactMap { subscription in
      guard !subscription.isIncome else { return nil }
      let age = context.daysSince(subscription.maturedDate)
      guard age >= 0, age <= windowDays else { return nil }
      let monthly = context.formatted(subscription.monthlyCostMagnitude)
      return Insight(
        id: "\(InsightKind.newRecurringDetected.rawValue):\(subscription.id)",
        kind: .newRecurringDetected,
        title: "New \(subscription.period.displayName) subscription",
        date: subscription.lastDate,
        framing: .neutral,
        actionability: .review,
        surprise: 0.45,
        monetaryImpact: amount(-subscription.monthlyCostMagnitude, context),
        facts: [
          InsightFact("Merchant", subscription.displayPayee),
          InsightFact("Cadence", subscription.period.displayName),
          InsightFact("Typical charge", context.formatted(subscription.medianAmount)),
          InsightFact("Monthly equivalent", monthly),
          InsightFact("Occurrences", "\(subscription.occurrenceCount)"),
        ],
        references: references(for: subscription))
    }
  }

  /// Latest charge exceeds the stream's prior median by more than
  /// `threshold` (design §A-2). Compares against the median of all
  /// occurrences *before* the latest, so a one-off spike still flags.
  static func priceHikes(
    _ subscriptions: [DetectedSubscription], context: InsightContext, threshold: Double = 0.05
  ) -> [Insight] {
    subscriptions.compactMap { subscription in
      guard subscription.amounts.count >= 3, !subscription.isIncome else { return nil }
      let priorMagnitudes = subscription.amounts.dropLast().map(magnitude)
      let priorMedian = DescriptiveStatistics.median(priorMagnitudes)
      let latest = magnitude(subscription.latestAmount)
      guard priorMedian > 0 else { return nil }
      let increase = (latest - priorMedian) / priorMedian
      guard increase > threshold else { return nil }

      let perChargeDelta = Decimal(latest - priorMedian)
      let monthlyDelta = perChargeDelta * subscription.period.occurrencesPerMonth
      return Insight(
        id: "\(InsightKind.subscriptionPriceHike.rawValue):\(subscription.id)",
        kind: .subscriptionPriceHike,
        title: "\(subscription.displayPayee) went up",
        date: subscription.lastDate,
        framing: .negative,
        actionability: .review,
        surprise: min(increase * 2, 1),
        monetaryImpact: amount(-monthlyDelta, context),
        facts: [
          InsightFact("Merchant", subscription.displayPayee),
          InsightFact("New charge", context.formatted(subscription.latestAmount)),
          InsightFact("Previous typical", context.formatted(amountDecimal(priorMedian, false))),
          InsightFact("Increase", percent(increase)),
          InsightFact("Extra per month", context.formatted(monthlyDelta)),
        ],
        references: references(for: subscription))
    }
  }

  /// Two or more active expense streams sharing a category with similar
  /// monthly cost — likely overlapping services (design §A-3). Emits one
  /// insight per category cluster.
  static func duplicates(
    _ subscriptions: [DetectedSubscription],
    categories: Categories,
    context: InsightContext,
    priceProximity: Double = 0.4
  ) -> [Insight] {
    let expenseStreams = subscriptions.filter { !$0.isIncome && $0.categoryId != nil }
    let byCategory = Dictionary(grouping: expenseStreams) { $0.categoryId }

    var insights: [Insight] = []
    for (categoryId, streams) in byCategory where streams.count >= 2 {
      guard let categoryId else { continue }
      let clustered = streams.filter { stream in
        streams.contains { other in
          other.id != stream.id
            && priceWithin(stream, other, proximity: priceProximity)
        }
      }
      guard clustered.count >= 2 else { continue }
      let names = clustered.map(\.displayPayee).sorted()
      let total = clustered.reduce(Decimal(0)) { $0 + $1.monthlyCostMagnitude }
      let categoryName =
        categories.by(id: categoryId).map { categories.path(for: $0) } ?? "this category"
      insights.append(
        Insight(
          id: "\(InsightKind.duplicateSubscription.rawValue):\(categoryId.uuidString)",
          kind: .duplicateSubscription,
          title: "Overlapping \(categoryName) subscriptions",
          date: context.now,
          framing: .negative,
          actionability: .act,
          surprise: 0.6,
          monetaryImpact: amount(-total, context),
          facts: [
            InsightFact("Category", categoryName),
            InsightFact("Services", names.joined(separator: ", ")),
            InsightFact("Combined monthly", context.formatted(total)),
          ],
          references: InsightReferences(
            categoryIds: [categoryId],
            instrumentIds: [context.reportingCurrency.id])))
    }
    return insights
  }

  /// Streams whose cadence is lengthening — the late-half median gap is
  /// markedly longer than the early-half (design §A-4, weak signal, so
  /// `review` not `act`). Needs at least four occurrences.
  static func cancellationCandidates(
    _ subscriptions: [DetectedSubscription], context: InsightContext, slowdown: Double = 1.4
  ) -> [Insight] {
    subscriptions.compactMap { subscription in
      guard !subscription.isIncome, subscription.amounts.count >= 4 else { return nil }
      let overdueDays = context.daysSince(subscription.lastDate)
      let expectedGap = subscription.medianIntervalDays
      guard expectedGap > 0, Double(overdueDays) > expectedGap * slowdown else { return nil }
      return Insight(
        id: "\(InsightKind.subscriptionCancellationCandidate.rawValue):\(subscription.id)",
        kind: .subscriptionCancellationCandidate,
        title: "Still paying for \(subscription.displayPayee)",
        date: subscription.lastDate,
        framing: .neutral,
        actionability: .review,
        surprise: 0.4,
        monetaryImpact: amount(-subscription.monthlyCostMagnitude, context),
        facts: [
          InsightFact("Merchant", subscription.displayPayee),
          InsightFact("Usual cadence", "every \(Int(expectedGap.rounded())) days"),
          InsightFact("Days since last", "\(overdueDays)"),
          InsightFact("Monthly cost", context.formatted(subscription.monthlyCostMagnitude)),
        ],
        references: references(for: subscription))
    }
  }

  // MARK: - Helpers

  private static func magnitude(_ value: Decimal) -> Double {
    Double(truncating: (value < 0 ? -value : value) as NSDecimalNumber)
  }

  private static func amountDecimal(_ positiveMagnitude: Double, _ isIncome: Bool) -> Decimal {
    Decimal(positiveMagnitude * (isIncome ? 1.0 : -1.0))
  }

  private static func priceWithin(
    _ lhs: DetectedSubscription, _ rhs: DetectedSubscription, proximity: Double
  ) -> Bool {
    let left = Double(truncating: lhs.monthlyCostMagnitude as NSDecimalNumber)
    let right = Double(truncating: rhs.monthlyCostMagnitude as NSDecimalNumber)
    let larger = max(left, right)
    guard larger > 0 else { return false }
    return abs(left - right) / larger <= proximity
  }

  private static func amount(_ quantity: Decimal, _ context: InsightContext) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: context.reportingCurrency)
  }

  private static func percent(_ fraction: Double) -> String {
    (fraction).formatted(.percent.precision(.fractionLength(0...1)))
  }

  private static func references(for subscription: DetectedSubscription) -> InsightReferences {
    InsightReferences(
      accountIds: subscription.accountId.map { [$0] } ?? [],
      categoryIds: subscription.categoryId.map { [$0] } ?? [])
  }
}
