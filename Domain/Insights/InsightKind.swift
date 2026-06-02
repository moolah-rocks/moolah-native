import Foundation

/// The catalog of personalized-insight types, numbered to match
/// `plans/2026-04-18-on-device-ai-design.md` §"Insight Catalog". Each
/// raw value is a stable identifier used to build per-insight ids and to
/// key the fatigue table — never rename one without a migration plan for
/// persisted dismissals.
///
/// All detection is deterministic (pure Swift); the Foundation Models
/// layer only narrates. See the design spec §"Where LLM Is Load-Bearing".
enum InsightKind: String, Sendable, Hashable, CaseIterable {
  // A. Recurring & Subscription Management
  case newRecurringDetected
  case subscriptionPriceHike
  case duplicateSubscription
  case subscriptionCancellationCandidate
  case subscriptionOverspend

  // B. Anomaly / Surprise Spending
  case largeTransactionAnomaly
  case newMerchantAlert
  case unusualDaySpend
  case categorySpendingAnomaly

  // C. Trends & Period Comparisons
  case categoryTrendRising
  case categoryTrendFalling
  case monthOverMonthDelta
  case categoryMixShift

  // D. Cash Flow & Forecasting
  case upcomingBillWarning
  case projectedMonthEndBalance
  case savingsRateTrend
  case runwayEstimate

  // E. Budget Performance (Earmarks)
  case earmarkBurndownProjection
  case earmarkUnderspend
  case savingsGoalETA

  // F. Savings Opportunities
  case idleCashAlert
  case feeSpend

  // G. Net Worth & Investments
  case netWorthMilestone
  case investmentConcentrationRisk
  case topPerformer
  case bottomPerformer
  case capitalGainsHarvest

  // H. Income Analysis
  case paycheckTimingPattern
  case incomeStabilityScore
  case missingPaycheckAlert
  case windfallIncome
  case payRateChange

  // K. Account structure (post-design-doc: account groups)
  case groupSpendConcentration

  // L. Data quality (post-design-doc: import provenance, transfer detection)
  case uncategorizedBacklog
  case unreconciledTransfers

  // M. Merchant & budget coverage
  case lapsedMerchant
  case weekendSpendSkew
  case unbudgetedCategory
}

extension InsightKind {
  /// Broad grouping used by the ranker and by category-scoped surfaces.
  var category: InsightCategory {
    switch self {
    case .newRecurringDetected, .subscriptionPriceHike, .duplicateSubscription,
      .subscriptionCancellationCandidate, .subscriptionOverspend, .lapsedMerchant:
      return .subscriptions
    case .largeTransactionAnomaly, .newMerchantAlert, .unusualDaySpend,
      .categorySpendingAnomaly:
      return .anomalies
    case .categoryTrendRising, .categoryTrendFalling, .monthOverMonthDelta,
      .categoryMixShift, .weekendSpendSkew:
      return .trends
    case .upcomingBillWarning, .projectedMonthEndBalance, .savingsRateTrend,
      .runwayEstimate:
      return .cashFlow
    case .earmarkBurndownProjection, .earmarkUnderspend, .savingsGoalETA,
      .unbudgetedCategory:
      return .budgets
    case .idleCashAlert, .feeSpend:
      return .savings
    case .netWorthMilestone, .investmentConcentrationRisk, .topPerformer,
      .bottomPerformer, .capitalGainsHarvest:
      return .investments
    case .paycheckTimingPattern, .incomeStabilityScore, .missingPaycheckAlert,
      .windfallIncome, .payRateChange:
      return .income
    case .groupSpendConcentration:
      return .accounts
    case .uncategorizedBacklog, .unreconciledTransfers:
      return .dataQuality
    }
  }
}

/// Coarse grouping of insight kinds. Drives surface routing (e.g. only
/// `cashFlow` insights appear on a per-account view) and the ranker's
/// per-category display caps.
enum InsightCategory: String, Sendable, Hashable, CaseIterable {
  case subscriptions
  case anomalies
  case trends
  case cashFlow
  case budgets
  case savings
  case investments
  case income
  case accounts
  case dataQuality
}
