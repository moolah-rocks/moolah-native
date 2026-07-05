import Foundation
import os

@testable import Moolah

/// An `AnalysisRepository` double whose `fetchCategoryBalancesByType` can be
/// paused mid-call exactly once, so a test can force a stale
/// `ReportingStore.loadCategoryBalances` call to publish *after* a fresher
/// call has already landed — the ordering that lets an out-of-order load
/// clobber fresher published state (the #1209 bug class). Overrides the
/// protocol-extension default directly (rather than gating the underlying
/// `fetchCategoryBalances`) so a single `armGate()` governs one whole
/// `loadCategoryBalances` call.
final class GatingAnalysisRepository: AnalysisRepository {
  private let armed = OSAllocatedUnfairLock(initialState: false)
  private let result = OSAllocatedUnfairLock(
    initialState: CategoryBalancesByType(
      income: [:], expense: [:], incomeUncategorised: nil, expenseUncategorised: nil))
  private let reached: AsyncStream<Void>
  private let reachedContinuation: AsyncStream<Void>.Continuation
  private let gate: AsyncStream<Void>
  private let gateContinuation: AsyncStream<Void>.Continuation

  init() {
    let reachedPair = AsyncStream<Void>.makeStream()
    reached = reachedPair.stream
    reachedContinuation = reachedPair.continuation
    let gatePair = AsyncStream<Void>.makeStream()
    gate = gatePair.stream
    gateContinuation = gatePair.continuation
  }

  /// Arm the gate so the *next* `fetchCategoryBalancesByType` call suspends.
  func armGate() { armed.withLock { $0 = true } }

  /// Suspends until a gated `fetchCategoryBalancesByType` call has begun.
  func waitUntilGateReached() async {
    var iterator = reached.makeAsyncIterator()
    _ = await iterator.next()
  }

  /// Releases the suspended `fetchCategoryBalancesByType` call.
  func releaseGate() { gateContinuation.yield(()) }

  /// Sets the value the *next* (non-gated, or post-release gated) call
  /// returns.
  func setResult(_ value: CategoryBalancesByType) { result.withLock { $0 = value } }

  func fetchCategoryBalancesByType(
    dateRange: ClosedRange<Date>,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalancesByType {
    let shouldGate = armed.withLock { state -> Bool in
      let value = state
      state = false
      return value
    }
    if shouldGate {
      reachedContinuation.yield(())
      var iterator = gate.makeAsyncIterator()
      _ = await iterator.next()
    }
    return result.withLock { $0 }
  }

  func fetchDailyBalances(
    after: Date?, forecastUntil: Date?
  ) async throws -> [DailyBalance] { [] }

  func fetchExpenseBreakdown(
    monthEnd: Int, after: Date?
  ) async throws -> [ExpenseBreakdown] { [] }

  func fetchIncomeAndExpense(
    monthEnd: Int, after: Date?
  ) async throws -> [MonthlyIncomeExpense] { [] }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> CategoryBalances {
    CategoryBalances(byCategory: [:], uncategorised: nil)
  }
}

extension GatingAnalysisRepository: Sendable {}
