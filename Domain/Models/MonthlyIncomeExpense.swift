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

  // --- Available-funds base (always includes earmark reserve movements) ---

  /// Income tracking available (spendable) funds: income legs on a
  /// spending account (bank / credit card / asset), with earmark reserve
  /// movements always applied. Setting money aside reads as a reduction,
  /// releasing it as a gain, and a spending-account leg that is also
  /// earmarked nets to zero (the cash arrived but is reserved). Excludes
  /// investment accounts — those are added via `investmentIncome`.
  let income: InstrumentAmount

  /// Expenses tracking available funds: expense legs on a spending
  /// account, with earmark reserve movements always applied — so a
  /// bank-paid-but-earmarked bill (e.g. a pre-funded tax payment) nets to
  /// zero. Excludes investment accounts.
  let expense: InstrumentAmount

  /// Profit = income + expense (can be negative). Expenses are stored as
  /// negative values by the project's sign convention, so the profit is the
  /// sum of the two signed amounts rather than a subtraction.
  let profit: InstrumentAmount

  // --- Investment layer (added by the "Include Investments" toggle) ---

  /// Investment-side income: income legs on investment / crypto /
  /// exchange accounts (dividends, staking, airdrops, token unlocks) and
  /// contributions transferred into investment accounts. Added to
  /// `income` for the toggle-on (cash + investments) view.
  let investmentIncome: InstrumentAmount

  /// Investment-side expenses: expense legs on investment / crypto /
  /// exchange accounts (brokerage / exchange / network fees) and
  /// withdrawals transferred out of investment accounts. Added to
  /// `expense` for the toggle-on view.
  let investmentExpense: InstrumentAmount

  /// Investment profit = investmentIncome + investmentExpense (signed
  /// sum). Added to `profit` for the toggle-on savings figure.
  let investmentProfit: InstrumentAmount

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
    investmentIncome: InstrumentAmount,
    investmentExpense: InstrumentAmount,
    investmentProfit: InstrumentAmount,
    hasUnavailableData: Bool = false
  ) {
    self.month = month
    self.start = start
    self.end = end
    self.income = income
    self.expense = expense
    self.profit = profit
    self.investmentIncome = investmentIncome
    self.investmentExpense = investmentExpense
    self.investmentProfit = investmentProfit
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
    case investmentIncome
    case investmentExpense
    case investmentProfit
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
    investmentIncome = try container.decode(InstrumentAmount.self, forKey: .investmentIncome)
    investmentExpense = try container.decode(InstrumentAmount.self, forKey: .investmentExpense)
    investmentProfit = try container.decode(InstrumentAmount.self, forKey: .investmentProfit)
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
    try container.encode(investmentIncome, forKey: .investmentIncome)
    try container.encode(investmentExpense, forKey: .investmentExpense)
    try container.encode(investmentProfit, forKey: .investmentProfit)
    try container.encode(hasUnavailableData, forKey: .hasUnavailableData)
  }
}

extension MonthlyIncomeExpense {
  /// Total income including the investment layer (cash + investments).
  var totalIncome: InstrumentAmount {
    income + investmentIncome
  }

  /// Total expenses including the investment layer.
  var totalExpense: InstrumentAmount {
    expense + investmentExpense
  }

  /// Total profit including the investment layer.
  var totalProfit: InstrumentAmount {
    profit + investmentProfit
  }
}
