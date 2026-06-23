/// Deterministic, model-free composer that turns an insight's structured
/// facts into one readable sentence — the non-AI fallback headline. Pure: no
/// model, no I/O, fully testable in CI without a device. Numbers come only
/// from fact values (verbatim) or the intact title; the composer never does
/// arithmetic and never invents a figure.
enum InsightDescriptionComposer {
  static func compose(kind: InsightKind, title: String, facts: [InsightFact]) -> String {
    let lookup = FactLookup(facts)
    switch kind.category {
    case .subscriptions: return composeSubscriptions(kind: kind, title: title, facts: lookup)
    case .anomalies: return composeAnomalies(kind: kind, title: title, facts: lookup)
    case .trends: return composeTrends(kind: kind, title: title, facts: lookup)
    case .cashFlow: return composeCashFlow(kind: kind, title: title, facts: lookup)
    case .budgets: return composeBudgets(kind: kind, title: title, facts: lookup)
    case .savings: return composeSavings(kind: kind, title: title, facts: lookup)
    case .investments: return composeInvestments(kind: kind, title: title, facts: lookup)
    case .income: return composeIncome(kind: kind, title: title, facts: lookup)
    case .accounts: return composeAccounts(kind: kind, title: title, facts: lookup)
    case .dataQuality: return composeDataQuality(kind: kind, title: title, facts: lookup)
    }
  }
}

// MARK: - Category dispatchers

extension InsightDescriptionComposer {
  static func composeSubscriptions(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .newRecurringDetected: return newRecurringDetected(title: title, facts: facts)
    case .subscriptionPriceHike: return subscriptionPriceHike(title: title, facts: facts)
    case .duplicateSubscription: return duplicateSubscription(title: title, facts: facts)
    case .subscriptionCancellationCandidate:
      return subscriptionCancellationCandidate(title: title, facts: facts)
    case .subscriptionOverspend: return subscriptionOverspend(title: title, facts: facts)
    case .lapsedMerchant: return lapsedMerchant(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeAnomalies(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .largeTransactionAnomaly: return largeTransactionAnomaly(title: title, facts: facts)
    case .newMerchantAlert: return newMerchantAlert(title: title, facts: facts)
    case .unusualDaySpend: return unusualDaySpend(title: title, facts: facts)
    case .categorySpendingAnomaly: return categorySpendingAnomaly(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeTrends(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .categoryTrendRising: return categoryTrendRising(title: title, facts: facts)
    case .categoryTrendFalling: return categoryTrendFalling(title: title, facts: facts)
    case .monthOverMonthDelta: return monthOverMonthDelta(title: title, facts: facts)
    case .categoryMixShift: return categoryMixShift(title: title, facts: facts)
    case .weekendSpendSkew: return weekendSpendSkew(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeCashFlow(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .upcomingBillWarning: return upcomingBillWarning(title: title, facts: facts)
    case .projectedMonthEndBalance: return projectedMonthEndBalance(title: title, facts: facts)
    case .savingsRateTrend: return savingsRateTrend(title: title, facts: facts)
    case .runwayEstimate: return runwayEstimate(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeBudgets(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .earmarkBurndownProjection:
      return earmarkBurndownProjection(title: title, facts: facts)
    case .earmarkUnderspend: return earmarkUnderspend(title: title, facts: facts)
    case .savingsGoalETA: return savingsGoalETA(title: title, facts: facts)
    case .unbudgetedCategory: return unbudgetedCategory(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeSavings(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .idleCashAlert: return idleCashAlert(title: title, facts: facts)
    case .feeSpend: return feeSpend(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeInvestments(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .netWorthMilestone: return netWorthMilestone(title: title, facts: facts)
    case .investmentConcentrationRisk:
      return investmentConcentrationRisk(title: title, facts: facts)
    case .topPerformer: return topPerformer(title: title, facts: facts)
    case .bottomPerformer: return bottomPerformer(title: title, facts: facts)
    case .capitalGainsHarvest: return capitalGainsHarvest(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeIncome(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .paycheckTimingPattern: return paycheckTimingPattern(title: title, facts: facts)
    case .incomeStabilityScore: return incomeStabilityScore(title: title, facts: facts)
    case .missingPaycheckAlert: return missingPaycheckAlert(title: title, facts: facts)
    case .windfallIncome: return windfallIncome(title: title, facts: facts)
    case .payRateChange: return payRateChange(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeAccounts(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .groupSpendConcentration: return groupSpendConcentration(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }

  static func composeDataQuality(
    kind: InsightKind, title: String, facts: FactLookup
  ) -> String {
    switch kind {
    case .uncategorizedBacklog: return uncategorizedBacklog(title: title, facts: facts)
    case .unreconciledTransfers: return unreconciledTransfers(title: title, facts: facts)
    default: fatalError("InsightDescriptionComposer: \(kind) routed to wrong category dispatcher")
    }
  }
}

// MARK: - Shared helpers

extension InsightDescriptionComposer {
  /// `true` when a signed "Change" fact ("+30%", "−30%") denotes an increase.
  static func changeIsIncrease(_ change: String) -> Bool { change.hasPrefix("+") }

  /// Strips a leading sign ("+", "−" U+2212, or ASCII "-") for prose that
  /// supplies the direction word separately.
  static func unsigned(_ value: String) -> String {
    if let first = value.first, first == "+" || first == "−" || first == "-" {
      return String(value.dropFirst())
    }
    return value
  }
}

/// Label-keyed access over an insight's `facts`. Exact-label lookup for the
/// common case; prefix lookup for detectors that embed a dynamic value in the
/// label ("Spent (90d)", "Typical Monday", "Over 6 months").
struct FactLookup {
  private let byLabel: [String: String]
  private let facts: [InsightFact]

  init(_ facts: [InsightFact]) {
    self.facts = facts
    byLabel = Dictionary(
      facts.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
  }
  func value(_ label: String) -> String? { byLabel[label] }
  func value(prefix: String) -> String? { facts.first { $0.label.hasPrefix(prefix) }?.value }
}
