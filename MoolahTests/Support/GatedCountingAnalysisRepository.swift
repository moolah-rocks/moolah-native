import Foundation

@testable import Moolah

/// Test double for `AnalysisRepository` that gates the FIRST `loadAll(...)`
/// call inside an `AsyncGate` (so a test can fire a burst of rate ticks
/// while the first reload is in flight) and counts every `loadAll(...)`.
/// Used by the rate-tick coalescing test. See issue #1075.
actor GatedCountingAnalysisRepository: AnalysisRepository {
  private(set) var loadAllCount = 0
  private let fetchStarted = AsyncGate()
  private let fetchRelease = AsyncGate()
  private var gatedFirstCall = true

  private let cannedBalances: [DailyBalance] = [
    DailyBalance(
      date: Date(timeIntervalSince1970: 0),
      balance: InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))
  ]

  /// Resolves once the first `loadAll(...)` has reached the gate.
  func waitUntilFetchStarted() async {
    await fetchStarted.wait()
  }

  /// Releases the gated first `loadAll(...)`.
  func releaseAll() async {
    await fetchRelease.open()
  }

  func loadAll(
    historyAfter: Date?, forecastUntil: Date?, monthEnd: Int
  ) async throws -> AnalysisData {
    loadAllCount += 1
    if gatedFirstCall {
      gatedFirstCall = false
      await fetchStarted.open()
      await fetchRelease.wait()
    }
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
