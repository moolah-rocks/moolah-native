import Foundation

/// Aggregated income and expenses for one financial month.
struct MonthlyIncomeExpense: Sendable, Identifiable, Hashable {
  var id: String { month }

  /// Financial month in YYYYMM format (e.g., "202604")
  let month: String

  /// First transaction date in this financial month (for display)
  let start: Date

  /// Last transaction date in this financial month (for display)
  let end: Date

  // --- Non-earmarked income & expenses ---

  /// Total income (excluding earmarked income) in cents
  let income: InstrumentAmount

  /// Total expenses (excluding earmarked expenses) in cents
  let expense: InstrumentAmount

  /// Profit = income + expense (can be negative). Expenses are stored as
  /// negative values by the project's sign convention, so the profit is the
  /// sum of the two signed amounts rather than a subtraction.
  let profit: InstrumentAmount

  // --- Earmarked income & expenses ---

  /// Income allocated to earmarks (including investment contributions)
  let earmarkedIncome: InstrumentAmount

  /// Expenses paid from earmarks (including investment withdrawals)
  let earmarkedExpense: InstrumentAmount

  /// Earmarked profit = earmarkedIncome - earmarkedExpense
  let earmarkedProfit: InstrumentAmount

  /// True when one or more rows in this month could not be priced due to a
  /// transient conversion error (e.g. crypto prices not yet warmed). The
  /// displayed totals may be understated; callers should surface this state.
  let hasUnavailableData: Bool

  // A memberwise init is retained (not redundant): `hasUnavailableData` has no
  // inline default — the default lives here — so the property stays a `let`
  // that `init(from:)` can still decode (an inline default would suppress
  // decoding). The default keeps every existing call site compiling.
  init(
    month: String,
    start: Date,
    end: Date,
    income: InstrumentAmount,
    expense: InstrumentAmount,
    profit: InstrumentAmount,
    earmarkedIncome: InstrumentAmount,
    earmarkedExpense: InstrumentAmount,
    earmarkedProfit: InstrumentAmount,
    hasUnavailableData: Bool = false
  ) {
    self.month = month
    self.start = start
    self.end = end
    self.income = income
    self.expense = expense
    self.profit = profit
    self.earmarkedIncome = earmarkedIncome
    self.earmarkedExpense = earmarkedExpense
    self.earmarkedProfit = earmarkedProfit
    self.hasUnavailableData = hasUnavailableData
  }
}

extension MonthlyIncomeExpense: Codable {
  private enum CodingKeys: String, CodingKey {
    case month
    case start
    case end
    case income
    case expense
    case profit
    case earmarkedIncome
    case earmarkedExpense
    case earmarkedProfit
    case hasUnavailableData
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    month = try container.decode(String.self, forKey: .month)
    start = try container.decode(Date.self, forKey: .start)
    end = try container.decode(Date.self, forKey: .end)
    income = try container.decode(InstrumentAmount.self, forKey: .income)
    expense = try container.decode(InstrumentAmount.self, forKey: .expense)
    profit = try container.decode(InstrumentAmount.self, forKey: .profit)
    earmarkedIncome = try container.decode(InstrumentAmount.self, forKey: .earmarkedIncome)
    earmarkedExpense = try container.decode(InstrumentAmount.self, forKey: .earmarkedExpense)
    earmarkedProfit = try container.decode(InstrumentAmount.self, forKey: .earmarkedProfit)
    hasUnavailableData =
      (try container.decodeIfPresent(Bool.self, forKey: .hasUnavailableData)) ?? false
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(month, forKey: .month)
    try container.encode(start, forKey: .start)
    try container.encode(end, forKey: .end)
    try container.encode(income, forKey: .income)
    try container.encode(expense, forKey: .expense)
    try container.encode(profit, forKey: .profit)
    try container.encode(earmarkedIncome, forKey: .earmarkedIncome)
    try container.encode(earmarkedExpense, forKey: .earmarkedExpense)
    try container.encode(earmarkedProfit, forKey: .earmarkedProfit)
    try container.encode(hasUnavailableData, forKey: .hasUnavailableData)
  }
}

extension MonthlyIncomeExpense {
  /// Compute total income (including earmarks)
  var totalIncome: InstrumentAmount {
    income + earmarkedIncome
  }

  /// Compute total expenses (including earmarks)
  var totalExpense: InstrumentAmount {
    expense + earmarkedExpense
  }

  /// Compute total profit (including earmarks)
  var totalProfit: InstrumentAmount {
    profit + earmarkedProfit
  }
}
