import Foundation
import Testing

@testable import Moolah

/// Contract tests for `AnalysisRepository.fetchCategoryBalances` — grouping,
/// scheduled-transaction exclusion, transaction-type filtering, date-range
/// filtering, and additional filters. The `CategoryBalances.uncategorised`
/// contract (routing, `nil`-when-absent, byCategory independence) is a
/// separate suite: `CategoryBalancesUncategorisedTests`.
@Suite("AnalysisRepository Contract Tests — Category Balances")
struct AnalysisCategoryBalancesTests {

  @Test("fetchCategoryBalances returns flat mapping")
  func categoryBalancesFlatMapping() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat1 = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat1)

    let cat2 = Category(id: UUID(), name: "Restaurants")
    _ = try await backend.categories.create(cat2)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    try await seedFlatMappingTransactions(
      backend: backend, account: account, cat1: cat1, cat2: cat2, date: today)

    let result = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil,
      targetInstrument: .defaultTestInstrument
    )

    #expect(
      result.byCategory[cat1.id]
        == InstrumentAmount(quantity: -70, instrument: .defaultTestInstrument))
    #expect(
      result.byCategory[cat2.id]
        == InstrumentAmount(quantity: -30, instrument: .defaultTestInstrument))
    // No uncategorised legs were seeded — `uncategorised` must be `nil`,
    // not `.zero`.
    #expect(result.uncategorised == nil)
  }

  @Test("fetchCategoryBalances excludes scheduled transactions")
  func categoryBalancesExcludesScheduled() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Rent")
    _ = try await backend.categories.create(cat)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Landlord",
        recurPeriod: .month, recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1000, type: .expense, categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Landlord",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1000, type: .expense, categoryId: cat.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil,
      targetInstrument: .defaultTestInstrument
    ).byCategory

    #expect(
      balances[cat.id] == InstrumentAmount(quantity: -1000, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances filters by transaction type")
  func categoryBalancesFiltersByType() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Salary")
    _ = try await backend.categories.create(cat)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 5000, type: .income, categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat.id)
        ]))

    let incomeBalances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .income,
      filters: nil, targetInstrument: .defaultTestInstrument
    ).byCategory

    #expect(
      incomeBalances[cat.id]
        == InstrumentAmount(quantity: 5000, instrument: .defaultTestInstrument))

    let expenseBalances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument
    ).byCategory

    #expect(
      expenseBalances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances respects date range")
  func categoryBalancesRespectsDateRange() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Gas")
    _ = try await backend.categories.create(cat)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let yesterday = try AnalysisTestHelpers.addingDaysCurrentCalendar(-1, to: today)
    let lastMonth = try AnalysisTestHelpers.addingMonthsCurrentCalendar(-1, to: today)

    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday, payee: "Gas Station",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: lastMonth, payee: "Gas Station",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense, categoryId: cat.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: yesterday...today, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument
    ).byCategory

    #expect(
      balances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances applies additional filters")
  func categoryBalancesAppliesFilters() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account1 = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account1)

    let account2 = Account(
      id: UUID(), name: "Credit Card", type: .creditCard, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account2)

    let cat = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account1.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account2.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense, categoryId: cat.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense,
      filters: TransactionFilter(accountId: account1.id),
      targetInstrument: .defaultTestInstrument
    ).byCategory

    #expect(
      balances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances handles empty result")
  func categoryBalancesEmptyResult() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    let result = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument)

    #expect(result.byCategory.isEmpty)
    #expect(result.uncategorised == nil)
  }

  // MARK: - Helpers

  private func seedFlatMappingTransactions(
    backend: CloudKitAnalysisTestBackend,
    account: Account,
    cat1: Moolah.Category,
    cat2: Moolah.Category,
    date: Date
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat1.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Restaurant",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense, categoryId: cat2.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Store 2",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense, categoryId: cat1.id)
        ]))
  }
}
