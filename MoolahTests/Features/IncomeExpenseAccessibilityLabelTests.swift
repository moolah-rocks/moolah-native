import Foundation
import Testing

@testable import Moolah

@Suite("IncomeExpenseTableCard — accessibilityLabel")
struct IncomeExpenseAccessibilityLabelTests {

  private let instrument: Instrument = .defaultTestInstrument

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  private func monthData(
    month: String,
    start: Date = Date(timeIntervalSince1970: 1_704_067_200),  // 2024-01-01
    income: Decimal,
    expense: Decimal,
    investmentIncome: Decimal = 0,
    investmentExpense: Decimal = 0
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: month,
      start: start,
      end: start,
      income: amount(income),
      expense: amount(expense),
      profit: amount(income - expense),
      investmentIncome: amount(investmentIncome),
      investmentExpense: amount(investmentExpense),
      investmentProfit: amount(investmentIncome - investmentExpense)
    )
  }

  @Test("combines month, income, expense, savings, and total savings")
  func combinesAllColumns() {
    let data = [
      monthData(month: "202401", income: Decimal(5000), expense: Decimal(3000))
    ]

    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeInvestments: false)

    // Must mention every column so VoiceOver reads the whole row.
    #expect(label.contains("Income"))
    #expect(label.contains("Expense"))
    #expect(label.contains("Savings"))
    #expect(label.contains("Total savings"))
    // Month label is included (formatted "MMM yyyy").
    #expect(label.contains(IncomeExpenseTableCard.monthLabel(for: data[0])))
    // Formatted amounts are included.
    #expect(label.contains(data[0].income.formatted))
    #expect(label.contains(data[0].expense.formatted))
    #expect(label.contains(data[0].profit.formatted))
  }

  @Test("includeInvestments switches to earmark-inclusive totals")
  func usesEarmarkTotalsWhenIncluded() {
    let data = [
      monthData(
        month: "202401", income: Decimal(5000), expense: Decimal(3000),
        investmentIncome: Decimal(1000), investmentExpense: Decimal(500))
    ]

    let withEarmarks = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeInvestments: true)
    let withoutEarmarks = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeInvestments: false)

    // Earmark-inclusive label should show totalIncome/totalExpense, not the plain values.
    #expect(withEarmarks.contains(data[0].totalIncome.formatted))
    #expect(withEarmarks.contains(data[0].totalExpense.formatted))
    #expect(withoutEarmarks.contains(data[0].income.formatted))
    #expect(withoutEarmarks.contains(data[0].expense.formatted))
    #expect(withEarmarks != withoutEarmarks)
  }

  @Test("total savings reflects cumulative position")
  func totalSavingsIsCumulative() throws {
    let data = [
      monthData(month: "202402", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202401", income: Decimal(4000), expense: Decimal(3500)),
    ]

    // Row at index 1 should include cumulative total 2000 + 500 = 2500.
    let column = IncomeExpenseTableCard.cumulativeSavingsColumn(
      in: data, includeInvestments: false)
    let cumulative = try #require(column[1])
    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[1], in: data, includeInvestments: false)

    #expect(label.contains(cumulative.formatted))
  }

  @Test("available row after an unavailable month announces total unavailable")
  func availableRowAfterUnavailableAnnouncesUnavailableTotal() {
    // Most-recent-first: available, unavailable, available. The trailing
    // available row's cumulative depends on the unknown middle month, so its
    // total must be announced as unavailable — never a (wrong) number.
    let data = [
      monthData(month: "202403", income: Decimal(5000), expense: Decimal(3000)),
      unavailableMonth(month: "202402"),
      monthData(month: "202401", income: Decimal(4000), expense: Decimal(3500)),
    ]

    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[2], in: data, includeInvestments: false)

    // Its own income/expense/savings are still announced...
    #expect(label.contains("Income"))
    #expect(label.contains(data[2].income.formatted))
    #expect(label.contains(data[2].expense.formatted))
    #expect(label.contains(data[2].profit.formatted))
    // ...but the running total is unavailable, not a number.
    #expect(label.contains("Total savings unavailable"))
    #expect(!label.contains("Total savings \(data[2].profit.formatted)"))
  }

  private func unavailableMonth(
    month: String,
    start: Date = Date(timeIntervalSince1970: 1_704_067_200)
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: month,
      start: start,
      end: start,
      income: amount(0),
      expense: amount(0),
      profit: amount(0),
      investmentIncome: amount(0),
      investmentExpense: amount(0),
      investmentProfit: amount(0),
      hasUnavailableData: true)
  }
}
