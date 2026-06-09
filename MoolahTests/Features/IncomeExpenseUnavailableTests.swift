import Foundation
import Testing

@testable import Moolah

@Suite("IncomeExpenseTableCard — unavailable months")
struct IncomeExpenseUnavailableTests {

  private let instrument: Instrument = .defaultTestInstrument

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  private func monthData(
    month: String,
    income: Decimal,
    expense: Decimal,
    hasUnavailableData: Bool = false
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: month,
      start: Date(timeIntervalSince1970: 1_704_067_200),  // 2024-01-01
      end: Date(timeIntervalSince1970: 1_704_067_200),
      income: amount(income),
      expense: amount(expense),
      profit: amount(income - expense),
      earmarkedIncome: amount(0),
      earmarkedExpense: amount(0),
      earmarkedProfit: amount(0),
      hasUnavailableData: hasUnavailableData
    )
  }

  // MARK: - Cumulative column

  @Test("cumulative goes nil from the first unavailable month onward")
  func cumulativeGoesNilFromUnavailable() {
    let data = [
      monthData(month: "202604", income: Decimal(10), expense: Decimal(0)),
      monthData(month: "202603", income: Decimal(0), expense: Decimal(0), hasUnavailableData: true),
      monthData(month: "202602", income: Decimal(5), expense: Decimal(0)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    #expect(column.count == 3)
    #expect(column[0]?.quantity == Decimal(10))
    #expect(column[1] == nil)
    #expect(column[2] == nil)
  }

  @Test("all-available data matches the running-total behaviour")
  func allAvailableMatchesRunningTotal() {
    let data = [
      monthData(month: "202604", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202603", income: Decimal(4000), expense: Decimal(3500)),
      monthData(month: "202602", income: Decimal(4500), expense: Decimal(2000)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    #expect(column[0]?.quantity == Decimal(2000))  // 5000 - 3000
    #expect(column[1]?.quantity == Decimal(2500))  // + (4000 - 3500)
    #expect(column[2]?.quantity == Decimal(5000))  // + (4500 - 2000)
  }

  @Test("column equals a plain running total for all-available data")
  func columnEqualsRunningTotal() {
    let data = [
      monthData(month: "202604", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202603", income: Decimal(4000), expense: Decimal(3500)),
      monthData(month: "202602", income: Decimal(4500), expense: Decimal(2000)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    var running = Decimal(0)
    for (index, item) in data.enumerated() {
      running += item.profit.quantity
      #expect(column[index]?.quantity == running)
    }
  }

  @Test("first row unavailable makes the whole column nil")
  func firstRowUnavailable() {
    let data = [
      monthData(month: "202604", income: Decimal(0), expense: Decimal(0), hasUnavailableData: true),
      monthData(month: "202603", income: Decimal(4000), expense: Decimal(3500)),
    ]

    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeEarmarks: false)

    #expect(column[0] == nil)
    #expect(column[1] == nil)
  }

  // MARK: - Accessibility

  @Test("unavailable row uses the data-unavailable label variant")
  func unavailableRowLabel() {
    let data = [
      monthData(month: "202604", income: Decimal(0), expense: Decimal(0), hasUnavailableData: true)
    ]

    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeEarmarks: false)

    let month = IncomeExpenseTableCard.monthLabel(for: data[0])
    #expect(label == "\(month): data unavailable, prices still loading")
  }

  @Test("available row label is unchanged by the unavailable variant")
  func availableRowLabelUnchanged() {
    let data = [
      monthData(month: "202604", income: Decimal(5000), expense: Decimal(3000))
    ]

    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeEarmarks: false)

    #expect(label.contains("Income"))
    #expect(label.contains(data[0].income.formatted))
    #expect(!label.contains("data unavailable"))
  }
}
