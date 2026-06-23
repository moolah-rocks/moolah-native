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

// MARK: - Arm funcs (filled in by later tasks; each returns `title` until then)

extension InsightDescriptionComposer {
  static func newRecurringDetected(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"),
      let monthly = facts.value("Monthly equivalent")
    else { return title }
    return "You've started a new \(merchant) subscription — about \(monthly) a month."
  }
  static func subscriptionPriceHike(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let newCharge = facts.value("New charge"),
      let extra = facts.value("Extra per month"), let increase = facts.value("Increase")
    else { return title }
    return
      "\(merchant) now costs \(newCharge) a month — \(extra) more than before, a \(increase) rise."
  }
  static func duplicateSubscription(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let services = facts.value("Services"),
      let combined = facts.value("Combined monthly")
    else { return title }
    return
      "You're paying for overlapping \(category) subscriptions (\(services)) — \(combined) a month combined."
  }
  static func subscriptionCancellationCandidate(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let monthly = facts.value("Monthly cost"),
      let days = facts.value("Days since last")
    else { return title }
    return
      "You're still paying \(monthly) a month for \(merchant), but there hasn't been a charge in \(days) days."
  }
  static func subscriptionOverspend(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Active subscriptions"),
      let monthly = facts.value("Monthly subscriptions"),
      let share = facts.value("Share of income")
    else { return title }
    return "Your \(count) subscriptions add up to \(monthly) a month — \(share) of your income."
  }
  static func largeTransactionAnomaly(title: String, facts: FactLookup) -> String {
    guard let amount = facts.value("Amount"), let merchant = facts.value("Merchant"),
      let category = facts.value("Category"), let typical = facts.value("Typical for category")
    else { return title }
    return
      "A \(amount) charge from \(merchant) stands out for \(category), where you usually spend around \(typical)."
  }
  static func newMerchantAlert(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let amount = facts.value("Amount")
    else { return title }
    return "Your first charge from \(merchant) came in at \(amount)."
  }
  static func unusualDaySpend(title: String, facts: FactLookup) -> String {
    guard let day = facts.value("Day"), let spent = facts.value("Spent"),
      let multiple = facts.value("Multiple"), let typical = facts.value("Typical \(day)")
    else { return title }
    return "You spent \(spent) on \(day) — around \(multiple) your usual \(typical)."
  }
  static func categorySpendingAnomaly(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let thisMonth = facts.value("This month"),
      let over = facts.value("Over by"), let expected = facts.value("Expected")
    else { return title }
    return
      "Your \(category) spending hit \(thisMonth) this month — about \(over) above your usual \(expected)."
  }
  static func categoryTrendRising(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let perMonth = facts.value("Per month")
    else { return title }
    return "Your \(category) spending is trending up, by about \(perMonth) a month."
  }
  static func categoryTrendFalling(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let perMonth = facts.value("Per month")
    else { return title }
    return "Your \(category) spending is easing off — down about \(perMonth) a month."
  }
  static func monthOverMonthDelta(title: String, facts: FactLookup) -> String {
    guard let thisPeriod = facts.value("This period"), let comparison = facts.value("Comparison"),
      let change = facts.value("Change")
    else { return title }
    let dir = changeIsIncrease(change) ? "up" : "down"
    return
      "You spent \(thisPeriod) this period, \(dir) \(unsigned(change)) from \(comparison) before."
  }
  static func categoryMixShift(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let share = facts.value("Current share"),
      let change = facts.value("Change")
    else { return title }
    let dir = changeIsIncrease(change) ? "up" : "down"
    return "\(category) now makes up \(share) of your spending, \(dir) \(unsigned(change))."
  }
  static func upcomingBillWarning(title: String, facts: FactLookup) -> String {
    guard let lowest = facts.value("Lowest projected"), let date = facts.value("On")
    else { return title }
    if let bill = facts.value("Upcoming bill") {
      return "Your balance is set to dip to \(lowest) around \(date), after \(bill)."
    }
    return "Your balance is set to dip to \(lowest) around \(date)."
  }
  static func projectedMonthEndBalance(title: String, facts: FactLookup) -> String {
    guard let balance = facts.value("Projected balance") else { return title }
    return "You're on track to finish the month with about \(balance)."
  }
  static func savingsRateTrend(title: String, facts: FactLookup) -> String {
    guard let rate = facts.value("Current savings rate"), let direction = facts.value("Direction")
    else { return title }
    if direction == "Rising" {
      return "Your savings rate is climbing — you're now saving \(rate) of your income."
    }
    return "Your savings rate has slipped to \(rate) of your income."
  }
  static func runwayEstimate(title: String, facts: FactLookup) -> String {
    guard let burn = facts.value("Monthly burn"), let funds = facts.value("Available funds"),
      let runway = facts.value("Runway")
    else { return title }
    return "At about \(burn) a month, your \(funds) would cover roughly \(runway)."
  }
  static func earmarkBurndownProjection(title: String, facts: FactLookup) -> String {
    guard let spent = facts.value("Spent so far"), let budget = facts.value("Budget"),
      let projected = facts.value("Projected")
    else { return title }
    return
      "\(title) — you've spent \(spent) of your \(budget) budget and you're on pace for \(projected)."
  }

  static func earmarkUnderspend(title: String, facts: FactLookup) -> String {
    guard let spent = facts.value("Spent so far"), let budget = facts.value("Budget"),
      let projected = facts.value("Projected")
    else { return title }
    return "\(title) — you've spent \(spent) of \(budget), on pace for just \(projected)."
  }

  static func savingsGoalETA(title: String, facts: FactLookup) -> String {
    guard let goal = facts.value("Goal"), let saved = facts.value("Saved") else { return title }
    guard let progress = facts.value("Progress") else {
      return "\(title) — you've saved \(saved) toward your \(goal) target."
    }
    if facts.value("Projected completion") != nil {
      return "\(title) — you've saved \(saved) of \(goal) (\(progress))."
    }
    return "\(title) — \(saved) saved toward \(goal)."
  }
  static func idleCashAlert(title: String, facts: FactLookup) -> String {
    guard let funds = facts.value("Available funds"), let excess = facts.value("Idle excess")
    else { return title }
    return
      "You've got \(funds) sitting in cash — about \(excess) more than you'd typically need on hand."
  }

  static func feeSpend(title: String, facts: FactLookup) -> String {
    guard let transactions = facts.value("Transactions") else { return title }
    return "\(title) over the past year, across \(transactions) charges."
  }

  static func netWorthMilestone(title: String, facts: FactLookup) -> String {
    guard let milestone = facts.value("Milestone"), let current = facts.value("Net worth")
    else { return title }
    return "Your net worth just passed \(milestone) and now sits at \(current)."
  }

  static func investmentConcentrationRisk(title: String, facts: FactLookup) -> String {
    guard let holding = facts.value("Holding"), let share = facts.value("Share of portfolio"),
      let value = facts.value("Value")
    else { return title }
    return "\(holding) now makes up \(share) of your investments, worth \(value)."
  }

  static func topPerformer(title: String, facts: FactLookup) -> String {
    guard let holding = facts.value("Holding"), let ret = facts.value("Return"),
      let gain = facts.value("Gain/loss"), let invested = facts.value("Invested")
    else { return title }
    return
      "\(holding) is your strongest holding, up \(ret) for a \(gain) gain on \(invested) invested."
  }

  static func bottomPerformer(title: String, facts: FactLookup) -> String {
    guard let holding = facts.value("Holding"), let ret = facts.value("Return"),
      let gain = facts.value("Gain/loss"), let invested = facts.value("Invested")
    else { return title }
    return "\(holding) is lagging — \(ret) on \(invested) invested, a \(gain) change."
  }

  static func capitalGainsHarvest(title: String, facts: FactLookup) -> String {
    guard let offset = facts.value("Potential offset"),
      let positions = facts.value("Loss positions")
    else { return title }
    return "You could offset \(offset) of realised gains against unrealised losses in \(positions)."
  }
  static func paycheckTimingPattern(title: String, facts: FactLookup) -> String { title }
  static func incomeStabilityScore(title: String, facts: FactLookup) -> String { title }
  static func missingPaycheckAlert(title: String, facts: FactLookup) -> String { title }
  static func windfallIncome(title: String, facts: FactLookup) -> String { title }
  static func payRateChange(title: String, facts: FactLookup) -> String { title }
  static func groupSpendConcentration(title: String, facts: FactLookup) -> String { title }
  static func uncategorizedBacklog(title: String, facts: FactLookup) -> String { title }
  static func unreconciledTransfers(title: String, facts: FactLookup) -> String { title }
  static func lapsedMerchant(title: String, facts: FactLookup) -> String { title }
  static func weekendSpendSkew(title: String, facts: FactLookup) -> String { title }
  static func unbudgetedCategory(title: String, facts: FactLookup) -> String { title }
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
