import Foundation

/// A point-in-time view of one earmark (budget / savings goal) already
/// reduced to the reporting currency, ready for the budget detectors.
///
/// `EarmarkStore` exposes converted balances as separate dictionaries
/// (`convertedBalances`, `convertedSavedAmounts`, `convertedSpentAmounts`);
/// the wiring layer joins them with the `Earmark` model into this snapshot
/// so detectors stay pure and currency-safe.
struct EarmarkSnapshot: Sendable, Identifiable, Hashable {
  let id: UUID
  let name: String
  /// Current balance held against the earmark, reporting currency.
  let balance: InstrumentAmount
  /// Amount spent from the earmark within its active window, reporting
  /// currency (positive magnitude). `nil` when unknown.
  let spent: InstrumentAmount?
  /// Total budgeted for the window (sum of line items), reporting currency.
  /// `nil` for a pure savings goal with no spending budget.
  let budget: InstrumentAmount?
  let savingsGoal: InstrumentAmount?
  /// Amount already saved toward `savingsGoal`, reporting currency.
  let saved: InstrumentAmount?
  let savingsStartDate: Date?
  let savingsEndDate: Date?
  let isHidden: Bool

  init(
    id: UUID,
    name: String,
    balance: InstrumentAmount,
    spent: InstrumentAmount? = nil,
    budget: InstrumentAmount? = nil,
    savingsGoal: InstrumentAmount? = nil,
    saved: InstrumentAmount? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil,
    isHidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.balance = balance
    self.spent = spent
    self.budget = budget
    self.savingsGoal = savingsGoal
    self.saved = saved
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
    self.isHidden = isHidden
  }
}

/// The full substrate handed to `InsightEngine`. Every monetary field is
/// pre-converted to `context.reportingCurrency`; every collection is
/// optional-by-emptiness (an empty array simply yields no insights from the
/// detectors that read it). The wiring layer assembles this from the
/// existing stores once per surface refresh.
struct InsightInput: Sendable {
  let context: InsightContext

  /// Posted (non-scheduled) income/expense records, all instruments folded
  /// into the reporting currency. The workhorse input for spend detectors.
  let transactions: [InsightTransaction]

  /// Per-financial-month income/expense aggregates (`AnalysisStore`).
  let monthly: [MonthlyIncomeExpense]

  /// Per-category per-month expense aggregates (`AnalysisStore`).
  let expenseBreakdown: [ExpenseBreakdown]

  /// Daily balance series including the forecast tail (`AnalysisStore`).
  let dailyBalances: [DailyBalance]

  /// Future-dated scheduled transactions (bills, recurring income), already
  /// in the reporting currency. Drives the upcoming-bill warning.
  let scheduledBills: [ScheduledBill]

  /// Converted earmark snapshots (`EarmarkStore`).
  let earmarks: [EarmarkSnapshot]

  /// Per-instrument P&L (`ReportingStore`), in the reporting currency.
  let profitLoss: [InstrumentProfitLoss]

  /// Realised capital-gain events for the current tax context
  /// (`ReportingStore`). Empty when no investments / not loaded.
  let capitalGains: [CapitalGainEvent]

  let categories: Categories

  init(
    context: InsightContext,
    transactions: [InsightTransaction] = [],
    monthly: [MonthlyIncomeExpense] = [],
    expenseBreakdown: [ExpenseBreakdown] = [],
    dailyBalances: [DailyBalance] = [],
    scheduledBills: [ScheduledBill] = [],
    earmarks: [EarmarkSnapshot] = [],
    profitLoss: [InstrumentProfitLoss] = [],
    capitalGains: [CapitalGainEvent] = [],
    categories: Categories = Categories(from: [])
  ) {
    self.context = context
    self.transactions = transactions
    self.monthly = monthly
    self.expenseBreakdown = expenseBreakdown
    self.dailyBalances = dailyBalances
    self.scheduledBills = scheduledBills
    self.earmarks = earmarks
    self.profitLoss = profitLoss
    self.capitalGains = capitalGains
    self.categories = categories
  }
}

/// A single upcoming scheduled outflow (or inflow) projected from a
/// recurring transaction, reduced to the reporting currency.
struct ScheduledBill: Sendable, Identifiable, Hashable {
  let id: UUID
  let date: Date
  let payee: String?
  /// Signed reporting-currency amount — negative for a bill (outflow).
  let amount: InstrumentAmount
  let accountId: UUID?

  init(id: UUID, date: Date, payee: String?, amount: InstrumentAmount, accountId: UUID?) {
    self.id = id
    self.date = date
    self.payee = payee
    self.amount = amount
    self.accountId = accountId
  }
}
