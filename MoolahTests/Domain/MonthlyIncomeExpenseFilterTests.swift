import Foundation
import Testing

@testable import Moolah

/// Tests the filter used to drill from a Monthly Income & Expense row into
/// that month's transactions.
@Suite("MonthlyIncomeExpense transactions filter")
struct MonthlyIncomeExpenseFilterTests {
  private func month(start: Date, end: Date) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: "202604",
      start: start,
      end: end,
      income: .zero(instrument: .AUD),
      expense: .zero(instrument: .AUD),
      profit: .zero(instrument: .AUD),
      investmentIncome: .zero(instrument: .AUD),
      investmentExpense: .zero(instrument: .AUD),
      investmentProfit: .zero(instrument: .AUD))
  }

  @Test("filter spans the month's transaction-date range")
  func filterSpansTransactionDateRange() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = Date(timeIntervalSince1970: 1_702_000_000)

    let filter = month(start: start, end: end).transactionsFilter

    #expect(filter.dateRange == start...end)
    // Only the date range is constrained — no account/earmark/category scoping.
    #expect(filter.accountId == nil)
    #expect(filter.earmarkId == nil)
    #expect(filter.categoryIds.isEmpty)
    #expect(filter.scheduled == .all)
  }

  @Test("filter handles a single-day month (start == end)")
  func filterHandlesSingleDayMonth() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)

    let filter = month(start: day, end: day).transactionsFilter

    #expect(filter.dateRange == day...day)
  }
}
