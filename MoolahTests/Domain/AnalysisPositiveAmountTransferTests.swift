import Foundation
import Testing

@testable import Moolah

/// Regression suite for investment-to-bank positive-amount transfers
/// (dividend reinvestments, etc.) and nil-accountId leg handling.
@Suite("AnalysisRepository Contract Tests — Positive-Amount Transfers")
struct AnalysisPositiveAmountTransferTests {

  @Test("daily balances handle positive-amount transfer from investment correctly")
  func positiveAmountTransferFromInvestment() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(checking)

    let investment = Account(
      id: UUID(), name: "Trust Shares", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    // Normal deposit: checking -> investment, negative amount on checking
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .transfer),
        ]))

    // Positive-amount transfer from investment (e.g. dividend reinvestment)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .transfer),
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)
    let todayBalance = try #require(balances.last)

    // Deposit: investments -= (-1000) = +1000; positive from_inv: investments += 5000
    // Total investments = 6000 cents = 60.00
    #expect(todayBalance.investments.quantity == 60)

    // Deposit: balance += (-1000) = -1000; positive from_inv: balance -= 5000 = -6000
    #expect(todayBalance.balance.quantity == -60)
  }

  @Test("income/expense handles positive-amount transfer from investment correctly")
  func positiveAmountTransferIncomeExpense() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(checking)

    let investment = Account(
      id: UUID(), name: "Trust Shares", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    // Positive-amount transfer from investment (e.g. dividend reinvestment credited)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    #expect(!data.isEmpty)
    let month = data[0]

    // Transfers go to the expense column. The checking leg (-50) is base
    // expense; the investment leg (+50) is investment expense. The
    // investment layer's profit rises by 50 (the asset grew), the base
    // falls by 50 (cash left), and the whole picture nets to zero.
    #expect(month.income.quantity == 0)
    #expect(month.expense.quantity == -50)
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.investmentExpense.quantity == 50)
    #expect(month.investmentProfit.quantity == 50)
    #expect(month.totalProfit.quantity == 0)
  }

  @Test("income/expense investmentProfit matches server formula for mixed transfers")
  func investmentProfitMatchesServer() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(checking)

    let investment = Account(
      id: UUID(), name: "Shares", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    try await seedMixedTransferLegs(
      backend: backend, checking: checking, investment: investment, date: today)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    let month = data[0]

    // Transfers all land in the expense column (both legs), so they net by
    // sign within the investment layer rather than splitting income/expense.
    // Investment legs: +10 (deposit) -5 (withdrawal) +30 (dividend) = +35.
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.investmentExpense.quantity == 35)
    #expect(month.investmentProfit.quantity == 35)

    // Current (checking) legs: -10 +5 -30 = -35 → base expense; the whole
    // picture (base + investments) nets to zero (only own money moved).
    #expect(month.expense.quantity == -35)
    #expect(month.totalProfit.quantity == 0)
  }

  @Test("dailyBalances excludes nil-accountId legs from balance")
  func dailyBalancesNilAccountIdExcluded() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Gift Fund", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Gift",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 50, type: .income, earmarkId: earmark.id)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = try #require(
      balances.first { AnalysisTestHelpers.currentCalendar.isDate($0.date, inSameDayAs: today) })

    #expect(todayBalance.balance.quantity == 100)
    #expect(todayBalance.earmarked.quantity == 50)
    #expect(todayBalance.availableFunds.quantity == 50)
  }

  // MARK: - Helpers

  private func seedMixedTransferLegs(
    backend: CloudKitAnalysisTestBackend,
    checking: Account,
    investment: Account,
    date: Date
  ) async throws {
    // Deposit: checking->investment, amount=-1000
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .transfer),
        ]))
    // Withdrawal: investment->checking, amount=-500
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .transfer),
        ]))
    // Dividend reinvest: investment->checking, amount=+3000
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 30, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .transfer),
        ]))
  }
}
