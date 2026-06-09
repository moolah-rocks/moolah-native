import Foundation

@testable import Moolah

/// Test double for `AnalysisRepository` that returns canned (non-empty)
/// data and counts how many times `loadAll(...)` runs. Used by the
/// rate-tick suite to prove that `reloadForRateTick()` bypasses the
/// `needsLoad` cache guard (the load count increments even when the
/// window is unchanged). See issue #1075.
actor CountingAnalysisRepository: AnalysisRepository {
  private(set) var loadAllCount = 0

  /// Canned daily balances so `hasCachedData` becomes true after the
  /// first load (the store's `needsLoad` guard requires non-empty
  /// `dailyBalances` to consider the cache populated).
  private let cannedBalances: [DailyBalance]

  init() {
    cannedBalances = [
      DailyBalance(
        date: Date(timeIntervalSince1970: 0),
        balance: InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))
    ]
  }

  func loadAll(
    historyAfter: Date?, forecastUntil: Date?, monthEnd: Int
  ) async throws -> AnalysisData {
    loadAllCount += 1
    return AnalysisData(
      dailyBalances: cannedBalances, expenseBreakdown: [], incomeAndExpense: [])
  }

  func fetchDailyBalances(after: Date?, forecastUntil: Date?) async throws -> [DailyBalance] {
    cannedBalances
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
  ) async throws -> [UUID: InstrumentAmount] {
    [:]
  }
}
