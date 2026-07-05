import Foundation

@testable import Moolah

/// Test double for `AnalysisRepository` that returns canned `CategoryBalances`
/// per `TransactionType`, so store-level tests can assert how
/// `ReportingStore.loadCategoryBalances` unwraps `CategoryBalancesByType`
/// (including the uncategorised totals and `hasUnavailableData` flags)
/// without needing a real GRDB-backed conversion failure to exercise Rule 11.
actor StubCategoryBalancesAnalysisRepository: AnalysisRepository {
  private let income: CategoryBalances
  private let expense: CategoryBalances

  init(income: CategoryBalances, expense: CategoryBalances) {
    self.income = income
    self.expense = expense
  }

  func fetchDailyBalances(after: Date?, forecastUntil: Date?) async throws -> [DailyBalance] {
    []
  }

  func fetchExpenseBreakdown(monthEnd: Int, after: Date?) async throws -> [ExpenseBreakdown] {
    []
  }

  func fetchIncomeAndExpense(
    monthEnd: Int, after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    []
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalances {
    switch transactionType {
    case .income: return income
    case .expense: return expense
    default: return CategoryBalances(byCategory: [:], uncategorised: nil)
    }
  }
}
