import Foundation
import Testing

@testable import Moolah

/// Contract tests for `AnalysisRepository.fetchDailyBalances` — ordering,
/// availability, earmark treatment, and the invariant between current-account
/// balance, investments, and netWorth.
@Suite("AnalysisRepository Contract Tests — Daily Balances")
struct AnalysisDailyBalancesTests {

  @Test("fetchDailyBalances returns empty array when no transactions")
  func dailyBalancesEmpty() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(balances.isEmpty)
  }

  @Test("fetchDailyBalances returns balances ordered by date")
  func dailyBalancesOrdering() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let yesterday = try AnalysisTestHelpers.addingDaysCurrentCalendar(-1, to: today)
    let twoDaysAgo = try AnalysisTestHelpers.addingDaysCurrentCalendar(-2, to: today)
    let halfDollar = try AnalysisTestHelpers.decimal("0.50")

    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday,
        payee: "Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: twoDaysAgo,
        payee: "Earlier Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: halfDollar, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    for index in 0..<(balances.count - 1) {
      #expect(balances[index].date <= balances[index + 1].date)
    }
  }

  @Test("fetchDailyBalances computes availableFunds correctly")
  func availableFundsCalculation() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Savings",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 1000, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Earmarked Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 300, type: .income,
            earmarkId: earmark.id)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    for balance in balances {
      #expect(balance.availableFunds == balance.balance - balance.earmarked)
    }
  }

  @Test("fetchDailyBalances with forecastUntil includes scheduled balances")
  func forecastIncludesScheduled() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Weekly Income",
        recurPeriod: .week,
        recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .income)
        ]))

    let future = try AnalysisTestHelpers.addingDaysCurrentCalendar(30, to: Date())
    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil,
      forecastUntil: future
    )

    let forecast = balances.filter(\.isForecast)
    #expect(!forecast.isEmpty, "Should have forecast balances")
  }

  @Test("earmarked balance in dailyBalances reflects earmarked transactions")
  func earmarkedBalanceFromTransactions() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(), name: "Holiday", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    try await seedEarmarkedLegs(
      backend: backend, account: account, earmark: earmark, date: today)

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = try #require(
      balances.first { AnalysisTestHelpers.currentCalendar.isDate($0.date, inSameDayAs: today) })

    // Total balance = 500 - 200 + 1000 = 1300 cents = 13.00
    #expect(todayBalance.balance.quantity == 13)
    // Earmarked = 500 - 200 = 300 cents = 3.00
    #expect(todayBalance.earmarked.quantity == 3)
    // Available = 1300 - 300 = 1000 cents = 10.00
    #expect(todayBalance.availableFunds.quantity == 10)
  }

  @Test("daily balance + position value equals total net worth")
  func balanceInvariantCrossCheck() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let accounts = try await seedCrossCheckAccounts(backend: backend)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    try await seedCrossCheckTransactions(backend: backend, accounts: accounts, date: today)

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)
    #expect(!balances.isEmpty)
    let todayBalance = try #require(balances.last)

    // balance = 5000 - 2000 + 1000 = 4000 cents = 40.00
    #expect(todayBalance.balance.quantity == 40)
    // position-derived investmentValue = 2000 cents = 20.00
    #expect(todayBalance.investmentValue?.quantity == 20)
    // netWorth = 4000 + 2000 = 6000 cents = 60.00
    #expect(todayBalance.netWorth.quantity == 60)
  }

  // MARK: - Helpers

  private struct CrossCheckAccounts {
    let checking: Account
    let savings: Account
    let investment: Account
  }

  private func seedCrossCheckAccounts(
    backend: CloudKitAnalysisTestBackend
  ) async throws -> CrossCheckAccounts {
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(checking)

    let savings = Account(
      id: UUID(), name: "Savings", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(savings)

    let investment = Account(
      id: UUID(), name: "Shares", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    return CrossCheckAccounts(checking: checking, savings: savings, investment: investment)
  }

  private func seedCrossCheckTransactions(
    backend: CloudKitAnalysisTestBackend,
    accounts: CrossCheckAccounts,
    date: Date
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: accounts.checking.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Invest",
        legs: [
          TransactionLeg(
            accountId: accounts.checking.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .transfer),
          TransactionLeg(
            accountId: accounts.investment.id, instrument: .defaultTestInstrument,
            quantity: 20, type: .transfer),
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Interest",
        legs: [
          TransactionLeg(
            accountId: accounts.savings.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))
  }

  private func seedEarmarkedLegs(
    backend: CloudKitAnalysisTestBackend,
    account: Account,
    earmark: Earmark,
    date: Date
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Earmarked Save",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .income, earmarkId: earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Earmarked Spend",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -2, type: .expense, earmarkId: earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Regular Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))
  }
}
