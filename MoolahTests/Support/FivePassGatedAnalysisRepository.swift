import Foundation

@testable import Moolah

/// Analysis repository that independently gates five loads so tests can inject
/// ticks throughout a bounded cycle and verify a cancelled pass is retried.
actor FivePassGatedAnalysisRepository: AnalysisRepository {
  private(set) var loadAllCount = 0
  private let firstStarted = AsyncGate()
  private let firstRelease = AsyncGate()
  private let secondStarted = AsyncGate()
  private let secondRelease = AsyncGate()
  private let thirdStarted = AsyncGate()
  private let thirdRelease = AsyncGate()
  private let fourthStarted = AsyncGate()
  private let fourthRelease = AsyncGate()
  private let fifthStarted = AsyncGate()
  private let fifthRelease = AsyncGate()

  func waitUntilFetchStarted(call: Int) async {
    switch call {
    case 1: await firstStarted.wait()
    case 2: await secondStarted.wait()
    case 3: await thirdStarted.wait()
    case 4: await fourthStarted.wait()
    case 5: await fifthStarted.wait()
    default: preconditionFailure("Only the first five calls are gated")
    }
  }

  func release(call: Int) async {
    switch call {
    case 1: await firstRelease.open()
    case 2: await secondRelease.open()
    case 3: await thirdRelease.open()
    case 4: await fourthRelease.open()
    case 5: await fifthRelease.open()
    default: preconditionFailure("Only the first five calls are gated")
    }
  }

  func loadAll(
    historyAfter: Date?, forecastUntil: Date?, monthEnd: Int
  ) async throws -> AnalysisData {
    loadAllCount += 1
    switch loadAllCount {
    case 1:
      await firstStarted.open()
      await firstRelease.wait()
    case 2:
      await secondStarted.open()
      await secondRelease.wait()
    case 3:
      await thirdStarted.open()
      await thirdRelease.wait()
    case 4:
      await fourthStarted.open()
      await fourthRelease.wait()
    case 5:
      await fifthStarted.open()
      await fifthRelease.wait()
    default:
      break
    }
    let cannedBalances = [
      DailyBalance(
        date: Date(timeIntervalSince1970: 0),
        balance: InstrumentAmount(
          quantity: Decimal(loadAllCount), instrument: .defaultTestInstrument))
    ]
    return AnalysisData(
      dailyBalances: cannedBalances, expenseBreakdown: [], incomeAndExpense: [])
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
    CategoryBalances(byCategory: [:], uncategorised: nil)
  }
}
