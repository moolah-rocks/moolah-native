import Foundation
import Testing

@testable import Moolah

/// Contract tests for `AnalysisRepository.fetchIncomeAndExpense` covering
/// financial-month grouping, profit computation, investment-transfer treatment,
/// earmark null-accountId handling, and refunds.
@Suite("AnalysisRepository Contract Tests — Income and Expense")
struct AnalysisIncomeExpenseTests {

  @Test("fetchIncomeAndExpense groups by financial month using monthEnd")
  func incomeExpenseMonthBoundary() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    // UTC-anchored dates: `financialMonth` extracts the UTC calendar
    // day so the boundary case is timezone-independent. Local-time
    // dates (`AnalysisTestHelpers.date`) drift on AEST/positive-UTC
    // runners — `2025-03-26 00:00 local` is `2025-03-25` in UTC and
    // both transactions would land in March instead of straddling
    // March/April. The CloudKit and GRDB analysis paths now both
    // forward to `FinancialMonth.key(for:monthEnd:)`, which is the
    // UTC-anchored helper this test must exercise.
    let onBoundary = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 25)
    let afterBoundary = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 26)

    _ = try await backend.transactions.create(
      Transaction(
        date: onBoundary, payee: "On boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: afterBoundary, payee: "After boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 20, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let march = data.first { $0.month == "202503" }
    let april = data.first { $0.month == "202504" }

    #expect(march != nil, "Should have March financial month")
    #expect(april != nil, "Should have April financial month")
    #expect(march?.income.quantity == 10)
    #expect(april?.income.quantity == 20)
  }

  @Test("fetchIncomeAndExpense computes profit correctly")
  func incomeExpenseProfitCalculation() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Expense",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -2, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    for month in data {
      #expect(month.profit == month.income + month.expense)
    }
  }

  @Test("fetchIncomeAndExpense handles investment transfers as earmarked")
  func investmentTransfersAsEarmarked() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let currentAccount = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(
      currentAccount,
      openingBalance: InstrumentAmount(quantity: 10, instrument: .defaultTestInstrument))

    let investmentAccount = Account(
      id: UUID(), name: "Investment", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investmentAccount)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Investment Contribution",
        legs: [
          TransactionLeg(
            accountId: currentAccount.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .transfer),
          TransactionLeg(
            accountId: investmentAccount.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    #expect(!data.isEmpty, "Should have at least one month")
  }

  @Test("fetchIncomeAndExpense classifies investment transfers correctly")
  func investmentTransferClassification() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let accounts = try await seedClassificationAccounts(backend: backend)
    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    try await seedClassificationTransactions(backend: backend, accounts: accounts, date: today)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty, "Should have at least one month")
    let month = data[0]

    // Transfers go to the expense column (both legs), so they net by sign.
    // Bank legs (current): -5 + 2 = -3 → base expense.
    #expect(month.expense.quantity == -3)
    // Investment legs: +5 -2 -1 +1 = +3 → investment expense.
    #expect(month.investmentExpense.quantity == 3)
    // Nothing lands in the income column.
    #expect(month.income.quantity == 0)
    #expect(month.investmentIncome.quantity == 0)
    // Whole picture: current↔investment moves net to zero.
    #expect(month.totalExpense.quantity == 0)
  }

  @Test("account-less earmark income is excluded from headline and negated in earmarked")
  func nullAccountIdEarmarkedHandling() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(), name: "Gift Fund", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    // Account-less earmark income (+5) sets money aside for later, which
    // reduces available funds now. Earmarks are always folded into the
    // base, so it lowers income by 5.
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Gift",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 5, type: .income, earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Available funds = salary (10) − amount set aside (5) = 5.
    #expect(month.income.quantity == 5)
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.totalIncome.quantity == 5)
  }

  @Test("expense refunds (positive quantity) reduce expense total, not increase it")
  func expenseRefundsReduceTotal() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Purchase",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -100, type: .expense)
        ]))

    // Refund: +30 (positive quantity with type .expense reduces expense total)
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Refund",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 30, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Net expense = -100 + 30 = -70 (refund reduces the total)
    #expect(month.expense.quantity == -70)
    #expect(month.profit == month.income + month.expense)
  }

  // MARK: - Helpers

  private struct ClassificationAccounts {
    let bank: Account
    let investmentA: Account
    let investmentB: Account
  }

  private func seedClassificationAccounts(
    backend: CloudKitAnalysisTestBackend
  ) async throws -> ClassificationAccounts {
    let bank = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)

    let investmentA = Account(
      id: UUID(), name: "Shares", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investmentA)

    let investmentB = Account(
      id: UUID(), name: "Bonds", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investmentB)

    return ClassificationAccounts(
      bank: bank, investmentA: investmentA, investmentB: investmentB)
  }

  private func seedClassificationTransactions(
    backend: CloudKitAnalysisTestBackend,
    accounts: ClassificationAccounts,
    date: Date
  ) async throws {
    // Bank -> Investment (should be investmentIncome)
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Invest",
        legs: [
          TransactionLeg(
            accountId: accounts.bank.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .transfer),
          TransactionLeg(
            accountId: accounts.investmentA.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .transfer),
        ]))
    // Investment -> Bank (should be investmentExpense)
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Withdraw",
        legs: [
          TransactionLeg(
            accountId: accounts.investmentA.id, instrument: .defaultTestInstrument,
            quantity: -2, type: .transfer),
          TransactionLeg(
            accountId: accounts.bank.id, instrument: .defaultTestInstrument,
            quantity: 2, type: .transfer),
        ]))
    // Investment -> Investment (should not affect income/expense)
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Rebalance",
        legs: [
          TransactionLeg(
            accountId: accounts.investmentA.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .transfer),
          TransactionLeg(
            accountId: accounts.investmentB.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .transfer),
        ]))
  }
}
