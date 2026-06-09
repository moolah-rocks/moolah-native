import Foundation
import Testing

@testable import Moolah

@Suite("IncomeExpenseTableCard — cumulativeSavingsColumn")
struct IncomeExpenseCumulativeSavingsTests {

  private let instrument: Instrument = .defaultTestInstrument

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  private func monthData(
    month: String,
    income: Decimal,
    expense: Decimal,
    earmarkedIncome: Decimal = 0,
    earmarkedExpense: Decimal = 0
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: month,
      start: Date(),
      end: Date(),
      income: amount(income),
      expense: amount(expense),
      profit: amount(income - expense),
      earmarkedIncome: amount(earmarkedIncome),
      earmarkedExpense: amount(earmarkedExpense),
      earmarkedProfit: amount(earmarkedIncome - earmarkedExpense)
    )
  }

  @Test("first row total savings equals its own savings")
  func firstRowEqualsOwnSavings() throws {
    let data = [
      monthData(month: "202604", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202603", income: Decimal(4000), expense: Decimal(3500)),
      monthData(month: "202602", income: Decimal(4500), expense: Decimal(2000)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    let first = try #require(column[0])
    #expect(first.quantity == Decimal(2000))  // 5000 - 3000
  }

  @Test("second row accumulates first two rows")
  func secondRowAccumulatesTwo() throws {
    let data = [
      monthData(month: "202604", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202603", income: Decimal(4000), expense: Decimal(3500)),
      monthData(month: "202602", income: Decimal(4500), expense: Decimal(2000)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    // (5000 - 3000) + (4000 - 3500) = 2000 + 500 = 2500
    let second = try #require(column[1])
    #expect(second.quantity == Decimal(2500))
  }

  @Test("last row is grand total of all savings")
  func lastRowIsGrandTotal() throws {
    let data = [
      monthData(month: "202604", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202603", income: Decimal(4000), expense: Decimal(3500)),
      monthData(month: "202602", income: Decimal(4500), expense: Decimal(2000)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    // 2000 + 500 + 2500 = 5000
    let last = try #require(column[2])
    #expect(last.quantity == Decimal(5000))
  }

  @Test("includeEarmarks uses totalProfit instead of profit")
  func includeEarmarksUsesTotalProfit() throws {
    let data = [
      monthData(
        month: "202604", income: Decimal(5000), expense: Decimal(3000),
        earmarkedIncome: Decimal(1000), earmarkedExpense: Decimal(500)),
      monthData(
        month: "202603", income: Decimal(4000), expense: Decimal(3500),
        earmarkedIncome: Decimal(200), earmarkedExpense: Decimal(100)),
    ]

    let withoutEarmarks = try #require(
      IncomeExpenseTableCard.cumulativeSavingsColumn(in: data, includeEarmarks: false)[1])
    let withEarmarks = try #require(
      IncomeExpenseTableCard.cumulativeSavingsColumn(in: data, includeEarmarks: true)[1])

    // Without: (5000-3000) + (4000-3500) = 2500
    #expect(withoutEarmarks.quantity == Decimal(2500))
    // With: (5000-3000+1000-500) + (4000-3500+200-100) = 2500 + 600 = 3100
    #expect(withEarmarks.quantity == Decimal(3100))
  }

  @Test("single row total equals its own savings")
  func singleRow() throws {
    let data = [
      monthData(month: "202604", income: Decimal(9000), expense: Decimal(8000))
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    let only = try #require(column[0])
    #expect(only.quantity == Decimal(1000))
  }

  @Test("handles negative savings correctly")
  func negativeSavings() throws {
    let data = [
      monthData(month: "202604", income: Decimal(2000), expense: Decimal(5000)),
      monthData(month: "202603", income: Decimal(3000), expense: Decimal(1000)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    let first = try #require(column[0])
    let second = try #require(column[1])
    #expect(first.quantity == Decimal(-3000))  // 2000 - 5000
    #expect(second.quantity == Decimal(-1000))  // -3000 + 2000
  }
}
