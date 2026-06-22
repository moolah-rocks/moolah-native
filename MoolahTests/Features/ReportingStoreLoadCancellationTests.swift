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
      transactionRepository: FailingTransactionRepository(),
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
}
