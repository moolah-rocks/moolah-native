import Foundation

@testable import Moolah

/// Shared builders for the insight detector tests. Keeps the suites focused
/// on behaviour rather than fixture plumbing, and pins every date to the
/// UTC calendar the detectors use so day/month maths is deterministic.
enum InsightTestSupport {
  static let currency = Instrument.fiat(code: "USD")
  static let calendar = InsightContext.defaultCalendar

  /// A fixed "today" the suites anchor to: 2026-06-15.
  static let now = date(2026, 6, 15)

  static func context(now: Date = now, monthEnd: Int = 31) -> InsightContext {
    InsightContext(
      now: now, reportingCurrency: currency, calendar: calendar, financialMonthEnd: monthEnd)
  }

  static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
  }

  /// `now` minus `days`.
  static func daysAgo(_ days: Int, from reference: Date = now) -> Date {
    calendar.date(byAdding: .day, value: -days, to: reference) ?? reference
  }

  /// An expense `InsightTransaction`. `amount` is the *positive magnitude*;
  /// it is stored negative to honour the sign convention.
  static func expense(
    _ magnitude: Decimal,
    payee: String,
    daysAgo days: Int,
    categoryId: UUID? = nil,
    categoryPath: String? = nil,
    accountId: UUID? = nil,
    id: UUID = UUID()
  ) -> InsightTransaction {
    InsightTransaction(
      id: id,
      date: daysAgo(days),
      rawPayee: payee,
      normalizedPayee: PayeeNormalizer.normalize(payee),
      amount: -magnitude,
      categoryId: categoryId,
      categoryPath: categoryPath,
      type: .expense,
      accountId: accountId)
  }

  /// An income `InsightTransaction`. `amount` is the positive magnitude.
  static func income(
    _ magnitude: Decimal,
    payee: String,
    daysAgo days: Int,
    accountId: UUID? = nil,
    id: UUID = UUID()
  ) -> InsightTransaction {
    InsightTransaction(
      id: id,
      date: daysAgo(days),
      rawPayee: payee,
      normalizedPayee: PayeeNormalizer.normalize(payee),
      amount: magnitude,
      categoryId: nil,
      categoryPath: nil,
      type: .income,
      accountId: accountId)
  }

  static func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: currency)
  }

  /// A `DailyBalance` offset from `now`: positive `offsetDays` is in the past,
  /// negative is the forecast tail in the future. `total` sets both
  /// current-funds balance and net worth; `forecast` flags a projected day.
  static func balance(offsetDays days: Int, total: Decimal, forecast: Bool) -> DailyBalance {
    let value = amount(total)
    let zero = amount(0)
    return DailyBalance(
      date: daysAgo(days),
      balance: value,
      earmarked: zero,
      availableFunds: value,
      investments: zero,
      investmentValue: nil,
      netWorth: value,
      bestFit: nil,
      isForecast: forecast)
  }

  // MARK: - Aggregate builders

  /// `InsightInput.recentCandidates` slice: legs within `windowDays` of `now`.
  /// Detectors that cite a `transactionId` (large-tx, windfall, new-merchant)
  /// only ever see this bounded window.
  static func recentCandidates(
    from legs: [InsightTransaction], windowDays: Int = 30, now: Date = InsightTestSupport.now
  ) -> [InsightTransaction] {
    let ctx = context(now: now)
    return legs.filter {
      let age = ctx.daysSince($0.date)
      return age >= 0 && age <= windowDays
    }
  }

  /// `[DailySpendSummary]` from synthetic legs, grouped by UTC calendar day
  /// with signed income/expense sums (mirrors the SQL aggregation).
  static func dailyTotals(from legs: [InsightTransaction]) -> [DailySpendSummary] {
    var expenseByDay: [Date: Decimal] = [:]
    var incomeByDay: [Date: Decimal] = [:]
    for leg in legs {
      let day = calendar.startOfDay(for: leg.date)
      if leg.isExpense {
        expenseByDay[day, default: 0] += leg.amount
      } else if leg.isIncome {
        incomeByDay[day, default: 0] += leg.amount
      }
    }
    let days = Set(expenseByDay.keys).union(incomeByDay.keys)
    return days.map { day in
      DailySpendSummary(
        day: day,
        expense: amount(expenseByDay[day] ?? 0),
        income: amount(incomeByDay[day] ?? 0))
    }
  }

  /// `[PayeeSummary]` from synthetic legs, one summary per
  /// `(normalizedPayee, direction)` with its occurrences ascending by date.
  static func payees(from legs: [InsightTransaction]) -> [PayeeSummary] {
    let groups = Dictionary(grouping: legs) {
      PayeeKey(normalized: $0.normalizedPayee, isExpense: $0.isExpense)
    }
    return groups.compactMap { key, members -> PayeeSummary? in
      guard !key.normalized.isEmpty else { return nil }
      let sorted = members.sorted { $0.date < $1.date }
      let occurrences = sorted.map {
        PayeeOccurrence(
          date: $0.date, amount: amount($0.amount), categoryId: $0.categoryId,
          accountId: $0.accountId)
      }
      let total = sorted.reduce(Decimal(0)) { $0 + $1.amount }
      return PayeeSummary(
        normalizedPayee: key.normalized,
        displayPayee: sorted.last?.rawPayee ?? key.normalized,
        isExpense: key.isExpense,
        occurrenceCount: sorted.count,
        firstSeen: sorted.first?.date ?? now,
        lastSeen: sorted.last?.date ?? now,
        windowedTotal: amount(total),
        occurrences: occurrences)
    }
  }

  /// `[CategorySpendSamples]` — positive expense magnitudes per category.
  /// Mirrors the SQL baseline, which only covers categorised expense legs.
  static func categorySamples(from legs: [InsightTransaction]) -> [CategorySpendSamples] {
    let expenses = legs.filter { $0.isExpense && $0.categoryId != nil }
    let groups = Dictionary(grouping: expenses) { $0.categoryId }
    return groups.map { categoryId, members in
      CategorySpendSamples(
        categoryId: categoryId,
        magnitudes: members.map(\.spendMagnitude))
    }
  }

  /// `[CategorySpendSummary]` — signed expense total per category over the
  /// implied window (the caller selects which legs to include).
  static func categorySpend(from legs: [InsightTransaction]) -> [CategorySpendSummary] {
    let groups = Dictionary(grouping: legs.filter(\.isExpense)) { $0.categoryId }
    return groups.map { categoryId, members in
      let total = members.reduce(Decimal(0)) { $0 + $1.amount }
      return CategorySpendSummary(
        categoryId: categoryId,
        categoryPath: members.first?.categoryPath,
        total: amount(total),
        legCount: members.count)
    }
  }

  /// `[AccountSpendSummary]` — signed expense total per account.
  static func accountSpend(from legs: [InsightTransaction]) -> [AccountSpendSummary] {
    let groups = Dictionary(grouping: legs.filter(\.isExpense)) { $0.accountId }
    return groups.map { accountId, members in
      let total = members.reduce(Decimal(0)) { $0 + $1.amount }
      return AccountSpendSummary(
        accountId: accountId, total: amount(total), legCount: members.count)
    }
  }

  private struct PayeeKey: Hashable {
    let normalized: String
    let isExpense: Bool
  }

  // MARK: - Monthly / breakdown builders

  /// A negative (expense-shaped) breakdown row.
  static func breakdownRow(_ magnitude: Decimal, categoryId: UUID?, month: String)
    -> ExpenseBreakdown
  {
    ExpenseBreakdown(categoryId: categoryId, month: month, totalExpenses: amount(-magnitude))
  }

  /// A monthly income/expense aggregate. `expense` is the positive
  /// magnitude; stored negative to match the backend's sign.
  static func monthly(
    month: String, income incomeMagnitude: Decimal, expense expenseMagnitude: Decimal
  ) -> MonthlyIncomeExpense {
    let income = amount(incomeMagnitude)
    let expense = amount(-expenseMagnitude)
    let zero = amount(0)
    return MonthlyIncomeExpense(
      month: month,
      start: CategorySpendSeries.monthDate(month) ?? now,
      end: CategorySpendSeries.monthDate(month) ?? now,
      income: income,
      expense: expense,
      profit: income + expense,
      investmentIncome: zero,
      investmentExpense: zero,
      investmentProfit: zero)
  }
}
