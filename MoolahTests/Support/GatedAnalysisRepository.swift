import Foundation

@testable import Moolah

/// Test double for `AnalysisRepository` that suspends every async method
/// inside an internal gate, giving tests a deterministic window in which
/// to cancel the surrounding `Task` before letting the gated method
/// resume. After release, the method calls `Task.checkCancellation()` so
/// it throws `CancellationError` exactly the way the production GRDB
/// repositories do (e.g. `GRDBAnalysisRepository+DailyBalances.swift`,
/// which rethrows cancellation per its documented contract).
///
/// Used by the `*LoadCancellationTests` suites to prove a `.task`
/// modifier's cancellation never surfaces as a user-facing error.
actor GatedAnalysisRepository: AnalysisRepository {
  private let fetchStarted = AsyncGate()
  private let fetchRelease = AsyncGate()

  /// Resolves once at least one repository method has reached the gate.
  func waitUntilFetchStarted() async {
    await fetchStarted.wait()
  }

  /// Wakes every gated waiter. Resumed methods re-check task
  /// cancellation and rethrow `CancellationError` if applicable.
  func releaseFetch() async {
    await fetchRelease.open()
  }

  private func gateThenCancelCheck() async throws {
    await fetchStarted.open()
    await fetchRelease.wait()
    try Task.checkCancellation()
  }

  func fetchDailyBalances(
    after: Date?, forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    try await gateThenCancelCheck()
    return []
  }

  func fetchExpenseBreakdown(
    monthEnd: Int, after: Date?
  ) async throws -> [ExpenseBreakdown] {
    try await gateThenCancelCheck()
    return []
  }

  func fetchIncomeAndExpense(
    monthEnd: Int, after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    try await gateThenCancelCheck()
    return []
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalances {
    try await gateThenCancelCheck()
    return CategoryBalances(byCategory: [:], uncategorised: nil)
  }
}
