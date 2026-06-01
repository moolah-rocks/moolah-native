import Foundation

/// A recurring cadence a subscription stream can settle into. Nominal day
/// counts match the design's target set `{7, 14, 30, 90, 365}`.
enum SubscriptionPeriod: String, Sendable, Hashable, CaseIterable {
  case weekly
  case fortnightly
  case monthly
  case quarterly
  case annual

  /// Nominal inter-arrival gap in days.
  var nominalDays: Double {
    switch self {
    case .weekly: return 7
    case .fortnightly: return 14
    case .monthly: return 30
    case .quarterly: return 91
    case .annual: return 365
    }
  }

  /// How many of this period fit in a calendar month — the multiplier that
  /// normalises a per-occurrence price to a monthly cost.
  var occurrencesPerMonth: Decimal {
    switch self {
    case .weekly: return Decimal(52) / Decimal(12)
    case .fortnightly: return Decimal(26) / Decimal(12)
    case .monthly: return 1
    case .quarterly: return Decimal(1) / Decimal(3)
    case .annual: return Decimal(1) / Decimal(12)
    }
  }

  var displayName: String {
    switch self {
    case .weekly: return "weekly"
    case .fortnightly: return "fortnightly"
    case .monthly: return "monthly"
    case .quarterly: return "quarterly"
    case .annual: return "annual"
    }
  }

  /// The period whose nominal gap is closest to `intervalDays`, accepted
  /// only when the relative error is within `tolerance` (default 25%).
  /// `nil` when the cadence doesn't resemble any subscription rhythm.
  static func nearest(toIntervalDays intervalDays: Double, tolerance: Double = 0.25)
    -> SubscriptionPeriod?
  {
    var best: SubscriptionPeriod?
    var bestError = Double.greatestFiniteMagnitude
    for period in allCases {
      let error = abs(intervalDays - period.nominalDays) / period.nominalDays
      if error < bestError {
        bestError = error
        best = period
      }
    }
    return bestError <= tolerance ? best : nil
  }
}

/// One detected recurring payment (or income) stream. The output of
/// `SubscriptionDetector` and the input to the subscription, paycheck, and
/// overspend insight detectors.
///
/// `medianAmount` / `latestAmount` are signed in the reporting currency —
/// negative for an expense stream, positive for income — preserving the
/// project's sign convention.
struct DetectedSubscription: Sendable, Identifiable, Hashable {
  let id: String
  let normalizedPayee: String
  let displayPayee: String
  let categoryId: UUID?
  let accountId: UUID?
  let period: SubscriptionPeriod
  let occurrenceCount: Int
  let firstDate: Date
  let lastDate: Date
  /// Date the stream reached its third occurrence — when it became a
  /// "confirmed" subscription. Drives the new-recurring insight.
  let maturedDate: Date
  let medianIntervalDays: Double
  let medianAmount: Decimal
  let latestAmount: Decimal
  /// Chronological signed amounts, for price-hike comparison and narration.
  let amounts: [Decimal]
  let isIncome: Bool

  /// Monthly-equivalent magnitude (always positive), for cost roll-ups.
  var monthlyCostMagnitude: Decimal {
    let magnitude = medianAmount < 0 ? -medianAmount : medianAmount
    return magnitude * period.occurrencesPerMonth
  }

  /// Projected next occurrence date, `lastDate + median interval`.
  func nextExpectedDate(calendar: Calendar) -> Date? {
    calendar.date(
      byAdding: .day, value: Int(medianIntervalDays.rounded()), to: lastDate)
  }
}
