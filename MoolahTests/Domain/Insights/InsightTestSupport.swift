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
      earmarkedIncome: zero,
      earmarkedExpense: zero,
      earmarkedProfit: zero)
  }
}
