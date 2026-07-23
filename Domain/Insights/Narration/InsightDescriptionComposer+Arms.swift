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
      let category = facts.value("Category"), let typical = facts.value("Typical for category"),
      let charges = facts.value("Baseline charges"), let window = facts.value("Baseline window")
    else { return title }
    return
      "A \(amount) charge from \(merchant) stands out against \(charges) \(category) charges from the last \(window), whose median was \(typical)."
  }
  static func newMerchantAlert(title: String, facts: FactLookup) -> String {
    guard let merchant = facts.value("Merchant"), let amount = facts.value("Amount"),
      let history = facts.value("Merchant history")
    else { return title }
    return "Your first charge from \(merchant) in the last \(history) came in at \(amount)."
  }
  static func unusualDaySpend(title: String, facts: FactLookup) -> String {
    guard let day = facts.value("Day"), let date = facts.value("Date"),
      let spent = facts.value("Spent"),
      let multiple = facts.value("Multiple"), let typical = facts.value("Typical \(day)"),
      let comparableDays = facts.value("Comparable days")
    else { return title }
    return
      "You spent \(spent) on \(date) — around \(multiple) the \(typical) median across \(comparableDays) other \(plural(comparableDays, day)) in your recorded history."
  }
  static func categorySpendingAnomaly(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let month = facts.value("Month"),
      let spent = facts.value("Spent"),
      let over = facts.value("Over by"), let expected = facts.value("Expected"),
      let seriesMonths = facts.value("Series months")
    else { return title }
    return
      "\(category) spending reached \(spent) in \(month) — \(over) above the \(expected) estimate based on \(seriesMonths) financial-month observations through \(month)."
  }
  static func categoryTrendRising(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let perMonth = facts.value("Per month"),
      let months = facts.value("Months analysed"), let through = facts.value("Through month")
    else { return title }
    return
      "Over the \(months) months through \(through), \(category) spending rose by about \(perMonth) a month."
  }
  static func categoryTrendFalling(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let perMonth = facts.value("Per month"),
      let months = facts.value("Months analysed"), let through = facts.value("Through month")
    else { return title }
    return
      "Over the \(months) months through \(through), \(category) spending fell by about \(perMonth) a month."
  }
  static func monthOverMonthDelta(title: String, facts: FactLookup) -> String {
    guard let latestMonth = facts.value("Latest month"),
      let latestSpend = facts.value("Latest spend"),
      let previousMonth = facts.value("Previous month"),
      let previousSpend = facts.value("Previous spend"),
      let change = facts.value("Change")
    else { return title }
    let dir = changeIsIncrease(change) ? "up" : "down"
    return
      "You spent \(latestSpend) in \(latestMonth), \(dir) \(unsigned(change)) from \(previousSpend) in \(previousMonth)."
  }
  static func categoryMixShift(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let share = facts.value("Current share"),
      let change = facts.value("Change"), let month = facts.value("Month"),
      let previousMonth = facts.value("Previous month")
    else { return title }
    let dir = changeIsIncrease(change) ? "up" : "down"
    return
      "\(category) made up \(share) of your spending in \(month), \(dir) \(unsigned(change)) from \(previousMonth)."
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
    guard let balance = facts.value("Projected balance"), let month = facts.value("Month")
    else { return title }
    return "You're on track to finish \(month) with about \(balance)."
  }
  static func savingsRateTrend(title: String, facts: FactLookup) -> String {
    guard let rate = facts.value("Current savings rate"), let direction = facts.value("Direction"),
      let months = facts.value("Months analysed"), let through = facts.value("Through month")
    else { return title }
    let verb = direction == "Rising" ? "climbed" : "fell"
    return
      "Across \(months) complete months through \(through), your savings rate \(verb) to \(rate)."
  }
  static func runwayEstimate(title: String, facts: FactLookup) -> String {
    guard let burn = facts.value("Monthly burn"), let funds = facts.value("Available funds"),
      let runway = facts.value("Runway"), let baselineMonths = facts.value("Baseline months")
    else { return title }
    return
      "Based on your last \(baselineMonths) complete financial \(plural(baselineMonths, "month")), a \(burn) monthly burn means your \(funds) would cover roughly \(runway)."
  }
  static func earmarkBurndownProjection(title: String, facts: FactLookup) -> String {
    guard let spent = facts.value("Spent so far"), let budget = facts.value("Budget"),
      let projected = facts.value("Projected"), let end = facts.value("Budget ends")
    else { return title }
    return
      "\(title) — you've spent \(spent) of \(budget) and are on pace for \(projected) by \(end)."
  }

  static func earmarkUnderspend(title: String, facts: FactLookup) -> String {
    guard let spent = facts.value("Spent so far"), let budget = facts.value("Budget"),
      let projected = facts.value("Projected"), let end = facts.value("Budget ends")
    else { return title }
    return
      "\(title) — you've spent \(spent) of \(budget) and are on pace for \(projected) by \(end)."
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
    guard let funds = facts.value("Available funds"), let excess = facts.value("Idle excess"),
      let baselineMonths = facts.value("Baseline months"),
      let bufferMonths = facts.value("Buffer months")
    else { return title }
    return
      "You've got \(funds) sitting in cash — \(excess) above a \(bufferMonths)-month buffer based on your last \(baselineMonths) complete financial \(plural(baselineMonths, "month"))."
  }

  static func feeSpend(title: String, facts: FactLookup) -> String {
    guard let transactions = facts.value("Transactions"), let window = facts.value("Window")
    else { return title }
    return
      "\(title) over the last \(window), across \(transactions) \(plural(transactions, "charge"))."
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
    guard let source = facts.value("Source"), let variation = facts.value("Variation"),
      let payments = facts.value("Payments analysed"),
      let history = facts.value("History window"), let cadence = facts.value("Cadence")
    else { return title }
    return
      "Across \(payments) \(cadence.lowercased()) payments from \(source) in the last \(history), amounts varied by about \(variation)."
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
      let typical = facts.value("Typical income"), let deposits = facts.value("Baseline deposits"),
      let window = facts.value("Baseline window")
    else { return title }
    return
      "You received \(amount) from \(source) — well above the \(typical) median across \(deposits) deposits from the last \(window)."
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
      let group = facts.value("Group"), let window = facts.value("Window")
    else { return title }
    return
      "Over the last \(window), \(share) of your spending — \(spent) — ran through \(group)."
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
    guard let weekend = facts.value("Typical weekend day"),
      let weekday = facts.value("Typical weekday"),
      let weekendDays = facts.value("Weekend days analysed"),
      let weekdays = facts.value("Weekdays analysed")
    else { return title }
    return
      "Across your recorded history, a typical weekend spending day was \(weekend), compared with \(weekday) on a weekday (\(weekendDays) weekend days and \(weekdays) weekdays)."
  }
  static func unbudgetedCategory(title: String, facts: FactLookup) -> String {
    guard let category = facts.value("Category"), let spent = facts.value("Spent"),
      let window = facts.value("Window")
    else { return title }
    return "\(category) has no budget, despite \(spent) of spending in the last \(window)."
  }
}
