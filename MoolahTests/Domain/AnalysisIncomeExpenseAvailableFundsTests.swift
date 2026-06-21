import Foundation
import Testing

@testable import Moolah

/// End-to-end contract test for the available-funds earmark model using a
/// tax-reserve workflow:
///   - salary lands in a bank account (real income),
///   - a chunk is set aside into a tax earmark via an account-less leg,
///   - the tax bill is paid from the bank account, tagged to the earmark,
///   - the surplus reserve is released via an account-less leg.
///
/// With "Include Earmarks & Investments" on, the figures track available
/// funds: setting money aside reads as a reduction, the bank-paid tax bill
/// nets to zero against its earmark drawdown, and releasing the surplus
/// reads as a gain. The headline (toggle-off) figures still show the raw
/// bank movements, including the lumpy tax payment.
@Suite("AnalysisRepository Contract Tests — Available-Funds Tax Workflow")
struct AnalysisIncomeExpenseAvailableFundsTests {
  @Test("tax-reserve workflow nets the bank-paid tax bill to zero with the toggle on")
  func taxReserveWorkflowNetsToAvailableFunds() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let bank = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    let tax = Earmark(id: UUID(), name: "Income Tax", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(tax)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    // Salary into the bank account (real income, no earmark).
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: 1000, type: .income)
        ]))
    // Set aside 47% for tax: account-less earmark income.
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Set aside for tax",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 470, type: .income, earmarkId: tax.id)
        ]))
    // Pay the tax bill from the bank account, tagged to the earmark.
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "ATO",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -200, type: .expense, earmarkId: tax.id)
        ]))
    // Release the surplus reserve: account-less earmark income (negative).
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Release surplus",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: -270, type: .income, earmarkId: tax.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    let month = try #require(data.first)

    // Available-funds base (earmarks always folded in):
    //   income  = 1000 salary − (470 set aside − 270 released) = 800
    //   expense = −200 bank tax bill − (−200 earmark drawdown)  = 0
    // The bank-paid tax bill nets to zero against its earmark drawdown,
    // and the net 200 still reserved reduces income.
    #expect(month.income.quantity == 800)
    #expect(month.expense.quantity == 0)
    #expect(month.profit.quantity == 800)

    // No investment accounts involved.
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.investmentExpense.quantity == 0)
    #expect(month.totalIncome.quantity == 800)
    #expect(month.totalExpense.quantity == 0)
    #expect(month.totalProfit.quantity == 800)
  }
}
