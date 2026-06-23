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
      "You're still paying \(monthly) a month for \(merchant), but there hasn't been a charge in \(days) \(plural(days, "day"))."
  }
  static func subscriptionOverspend(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Active subscriptions"),
      let monthly = facts.value("Monthly subscriptions"),
      let share = facts.value("Share of income")
    else { return title }
    let verb = count == "1" ? "adds" : "add"
    return
      "Your \(count) \(plural(count, "subscription")) \(verb) up to \(monthly) a month — \(share) of your income."
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
    return "\(title) over the past year, across \(transactions) \(plural(transactions, "charge"))."
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
  static func paycheckTimingPattern(title: String, facts: FactLookup) -> String {
    guard let source = facts.value("Source"), let amount = facts.value("Typical amount"),
      let next = facts.value("Next expected")
    else { return title }
    return "Your next \(source) paycheck of about \(amount) should land around \(next)."
  }
  static func incomeStabilityScore(title: String, facts: FactLookup) -> String {
    guard let variation = facts.value("Variation") else { return title }
    return "\(title) — it varies by about \(variation) month to month."
  }
  static func missingPaycheckAlert(title: String, facts: FactLookup) -> String {
    guard let source = facts.value("Source"), let amount = facts.value("Typical amount"),
      let expected = facts.value("Expected"), let overdue = facts.value("Days overdue")
    else { return title }
    return
      "Your \(source) paycheck of around \(amount) was expected \(expected) and is \(overdue) \(plural(overdue, "day")) late."
  }
  static func windfallIncome(title: String, facts: FactLookup) -> String {
    guard let amount = facts.value("Amount"), let source = facts.value("Source"),
      let typical = facts.value("Typical income")
    else { return title }
    return "You received \(amount) from \(source) — well above your typical \(typical)."
  }
  static func payRateChange(title: String, facts: FactLookup) -> String {
    guard let source = facts.value("Source"), let newAmount = facts.value("New amount"),
      let previous = facts.value("Previous"), let change = facts.value("Change")
    else { return title }
    let verb = changeIsIncrease(change) ? "rose" : "dropped"
    return "Your \(source) pay \(verb) to \(newAmount) from \(previous)."
  }
  static func groupSpendConcentration(title: String, facts: FactLookup) -> String {
    guard let share = facts.value("Share of spend"), let spent = facts.value("Spent"),
      let group = facts.value("Group")
    else { return title }
    return "\(share) of your spending — \(spent) — runs through \(group)."
  }
  static func uncategorizedBacklog(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Uncategorized") else { return title }
    return "You've got \(count) \(plural(count, "transaction")) waiting for a category."
  }
  static func unreconciledTransfers(title: String, facts: FactLookup) -> String {
    guard let count = facts.value("Pending transfers") else { return title }
    let verb = count == "1" ? "is" : "are"
    return "There \(verb) \(count) possible \(plural(count, "transfer")) to review and merge."
  }
  static func lapsedMerchant(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let days = facts.value("Days since last")
    else { return title }
    return "You haven't paid \(merchant) in \(days) \(plural(days, "day"))."
  }
  static func weekendSpendSkew(title: String, facts: FactLookup) -> String {
    guard let weekend = facts.value("Avg weekend day"), let weekday = facts.value("Avg weekday")
    else { return title }
    return
      "You spend more on weekends — about \(weekend) a weekend day versus \(weekday) on weekdays."
  }
  static func unbudgetedCategory(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let spent = facts.value(prefix: "Spent")
    else { return title }
    return "\(category) has no budget yet — you've spent \(spent) there recently."
  }
}
