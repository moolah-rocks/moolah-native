import Foundation
import Testing

@testable import Moolah

@Suite("ReportingStore — load cancellation")
@MainActor
struct ReportingStoreLoadCancellationTests {

  /// `loadCategoryBalances` cancelled mid-fetch must NOT surface
  /// `CancellationError` on `categoryBalancesError`. `ReportsView`'s
  /// `.task(id:)` is cancelled whenever the user switches date ranges;
  /// leaking the cancellation rendered "Swift.CancellationError error 1"
  /// where the report should be.
  @Test
  func cancelledLoadCategoryBalancesDoesNotSurfaceCancellationError() async throws {
    let analysisRepository = GatedAnalysisRepository()
    let store = ReportingStore(
      analysisRepository: analysisRepository,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: .defaultTestInstrument
    )

    let dateRange = Date().addingTimeInterval(-86_400)...Date()
    let task = Task { @MainActor in
      await store.loadCategoryBalances(dateRange: dateRange)
    }
    await analysisRepository.waitUntilFetchStarted()
    task.cancel()
    await analysisRepository.releaseFetch()
    await task.value

    #expect(store.categoryBalancesError == nil)
    #expect(!store.isLoadingCategoryBalances)
  }

  @Test("default owner changes discard stale in-flight tax income summaries")
  func defaultOwnerChangesDiscardStaleTaxIncomeSummaries() async {
    let originalOwnerId = UUID()
    let updatedOwnerId = UUID()
    let repository = GatedTaxIncomeAnalysisRepository(ownerId: originalOwnerId)
    let store = ReportingStore(
      analysisRepository: repository,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: .defaultTestInstrument,
      defaultTaxOwnerId: originalOwnerId)

    let task = Task { @MainActor in
      await store.loadTaxReport(financialYear: 2026)
    }
    await repository.waitUntilFetchStarted()
    store.updateDefaultTaxOwnerId(updatedOwnerId)
    await repository.releaseFetch()
    await task.value

    #expect(store.defaultTaxOwnerId == updatedOwnerId)
    #expect(store.taxIncomeExpenseSummaries.isEmpty)
    #expect(!store.isLoading)
  }
}

private actor GatedTaxIncomeAnalysisRepository: AnalysisRepository {
  private let ownerId: UUID
  private let fetchStarted = AsyncGate()
  private let fetchRelease = AsyncGate()

  init(ownerId: UUID) {
    self.ownerId = ownerId
  }

  func waitUntilFetchStarted() async {
    await fetchStarted.wait()
  }

  func releaseFetch() async {
    await fetchRelease.open()
  }

  func fetchDailyBalances(after _: Date?, forecastUntil _: Date?) async throws -> [DailyBalance] {
    []
  }

  func fetchExpenseBreakdown(monthEnd _: Int, after _: Date?) async throws -> [ExpenseBreakdown] {
    []
  }

  func fetchIncomeAndExpense(monthEnd _: Int, after _: Date?) async throws -> [MonthlyIncomeExpense]
  {
    []
  }

  func fetchCategoryBalances(
    dateRange _: ClosedRange<Date>,
    transactionType _: TransactionType,
    filters _: TransactionFilter?,
    targetInstrument _: Instrument
  ) async throws -> CategoryBalances {
    CategoryBalances(byCategory: [:], uncategorised: nil)
  }

  func fetchTaxIncomeExpenseSummaries(
    dateInterval _: Range<Date>,
    targetInstrument: Instrument,
    defaultTaxOwnerId _: UUID
  ) async throws -> [TaxIncomeExpenseSummary] {
    await fetchStarted.open()
    await fetchRelease.wait()
    return [
      TaxIncomeExpenseSummary(
        ownerId: ownerId,
        taxableIncome: InstrumentAmount(quantity: 100, instrument: targetInstrument),
        deductibleExpenses: InstrumentAmount(quantity: 0, instrument: targetInstrument))
    ]
  }
}
