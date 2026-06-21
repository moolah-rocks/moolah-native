import Foundation
import Testing

@testable import Moolah

@Suite("Domain Models Tests")
struct DomainModelsTests {

  // MARK: - DailyBalance Tests

  @Test("DailyBalance computes availableFunds correctly")
  func dailyBalanceAvailableFunds() {
    let balance = DailyBalance(
      date: Date(),
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument),
      earmarked: InstrumentAmount(
        quantity: Decimal(30000) / 100, instrument: .defaultTestInstrument),
      investments: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(balance.availableFunds.quantity == Decimal(70000) / 100)  // 100000 - 30000
  }

  @Test("DailyBalance computes netWorth with investments only")
  func dailyBalanceNetWorthInvestments() {
    let balance = DailyBalance(
      date: Date(),
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument),
      earmarked: InstrumentAmount(quantity: Decimal(0) / 100, instrument: .defaultTestInstrument),
      investments: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      investmentValue: nil
    )

    #expect(balance.netWorth.quantity == Decimal(150000) / 100)  // 100000 + 50000
  }

  @Test("DailyBalance computes netWorth with investmentValue")
  func dailyBalanceNetWorthInvestmentValue() {
    let balance = DailyBalance(
      date: Date(),
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument),
      earmarked: InstrumentAmount(quantity: Decimal(0) / 100, instrument: .defaultTestInstrument),
      investments: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      investmentValue: InstrumentAmount(
        quantity: Decimal(60000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(balance.netWorth.quantity == Decimal(160000) / 100)  // 100000 + 60000 (uses investmentValue)
  }

  @Test("DailyBalance convenience initializer sets isForecast to false")
  func dailyBalanceConvenienceInitializer() {
    let balance = DailyBalance(
      date: Date(),
      balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(balance.isForecast == false)
    #expect(balance.bestFit == nil)
  }

  @Test("DailyBalance id is ISO8601 date string")
  func dailyBalanceId() {
    let date = Date(timeIntervalSince1970: 1_672_531_200)  // 2023-01-01
    let balance = DailyBalance(
      date: date,
      balance: .zero(instrument: .defaultTestInstrument)
    )

    #expect(balance.id == date.ISO8601Format())
  }

  // MARK: - ExpenseBreakdown Tests

  @Test("ExpenseBreakdown id combines category and month")
  func expenseBreakdownId() {
    let categoryId = UUID()
    let breakdown = ExpenseBreakdown(
      categoryId: categoryId,
      month: "202604",
      totalExpenses: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(breakdown.id == "\(categoryId.uuidString)-202604")
  }

  @Test("ExpenseBreakdown id handles uncategorized")
  func expenseBreakdownUncategorizedId() {
    let breakdown = ExpenseBreakdown(
      categoryId: nil,
      month: "202604",
      totalExpenses: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(breakdown.id == "uncategorized-202604")
  }

  @Test("ExpenseBreakdown monthDate parses YYYYMM format")
  func expenseBreakdownMonthDate() throws {
    let breakdown = ExpenseBreakdown(
      categoryId: nil,
      month: "202604",
      totalExpenses: .zero(instrument: .defaultTestInstrument)
    )

    let monthDate = try #require(breakdown.monthDate)

    // `monthDate` parses the YYYYMM label in UTC (a financial-month label
    // must map to the same instant on every host), so read the components
    // back through a UTC calendar — `Calendar.current` would shift the
    // midnight-UTC instant into the prior month in any UTC-negative zone.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let components = calendar.dateComponents([.year, .month], from: monthDate)
    #expect(components.year == 2026)
    #expect(components.month == 4)
  }

  // MARK: - MonthlyIncomeExpense Tests

  @Test("MonthlyIncomeExpense computes totalIncome")
  func monthlyIncomeExpenseTotalIncome() {
    let data = MonthlyIncomeExpense(
      month: "202604",
      start: Date(),
      end: Date(),
      income: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument),
      expense: InstrumentAmount(quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      profit: InstrumentAmount(quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      investmentIncome: InstrumentAmount(
        quantity: Decimal(20000) / 100, instrument: .defaultTestInstrument),
      investmentExpense: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: .defaultTestInstrument),
      investmentProfit: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(data.totalIncome.quantity == Decimal(120000) / 100)  // 100000 + 20000
  }

  @Test("MonthlyIncomeExpense computes totalExpense")
  func monthlyIncomeExpenseTotalExpense() {
    let data = MonthlyIncomeExpense(
      month: "202604",
      start: Date(),
      end: Date(),
      income: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument),
      expense: InstrumentAmount(quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      profit: InstrumentAmount(quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      investmentIncome: InstrumentAmount(
        quantity: Decimal(20000) / 100, instrument: .defaultTestInstrument),
      investmentExpense: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: .defaultTestInstrument),
      investmentProfit: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(data.totalExpense.quantity == Decimal(60000) / 100)  // 50000 + 10000
  }

  @Test("MonthlyIncomeExpense computes totalProfit")
  func monthlyIncomeExpenseTotalProfit() {
    let data = MonthlyIncomeExpense(
      month: "202604",
      start: Date(),
      end: Date(),
      income: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: .defaultTestInstrument),
      expense: InstrumentAmount(quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      profit: InstrumentAmount(quantity: Decimal(50000) / 100, instrument: .defaultTestInstrument),
      investmentIncome: InstrumentAmount(
        quantity: Decimal(20000) / 100, instrument: .defaultTestInstrument),
      investmentExpense: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: .defaultTestInstrument),
      investmentProfit: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: .defaultTestInstrument)
    )

    #expect(data.totalProfit.quantity == Decimal(60000) / 100)  // 50000 + 10000
  }
}
