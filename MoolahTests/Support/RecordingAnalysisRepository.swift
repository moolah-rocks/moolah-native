import Foundation

@testable import Moolah

/// Test double for `AnalysisRepository` that records how `AnalysisStore` drives
/// it — the number of loads and the most recent `after` window — and returns a
/// single non-empty daily balance so `hasCachedData` flips true after a load.
/// Verifies `loadAll`'s cache gate (narrowing must not refetch; widening or a
/// forecast change must).
actor RecordingAnalysisRepository: AnalysisRepository {
  private(set) var loadCount = 0
  private(set) var lastAfter: Date?
  private let breakdown: [ExpenseBreakdown]

  init(breakdown: [ExpenseBreakdown] = []) {
    self.breakdown = breakdown
  }

  func fetchDailyBalances(after: Date?, forecastUntil: Date?) async throws -> [DailyBalance] {
    loadCount += 1
    lastAfter = after
    return [
      DailyBalance(
        date: Date(),
        balance: InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))
    ]
  }

  func fetchExpenseBreakdown(
    monthEnd: Int, after: Date?
  ) async throws -> [ExpenseBreakdown] { breakdown }

  func fetchIncomeAndExpense(
    monthEnd: Int, after: Date?
  ) async throws -> [MonthlyIncomeExpense] { [] }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalances { CategoryBalances(byCategory: [:], uncategorised: nil) }
}
