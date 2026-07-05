import Foundation
import Testing

@testable import Moolah

/// Regression for #1209. `loadCategoryBalances` is invoked both from
/// `ReportsView`'s `.task(id:)` (re-keyed on date-range change) and from the
/// "Try Again" button — nothing prevented an older, slower-to-resolve call
/// from publishing its stale result *after* a fresher call already landed.
/// This is the same "superseded async load clobbers fresher state" class
/// that `AccountStore.snapshotGeneration` guards against; `ReportingStore`
/// now guards `loadCategoryBalances` (and `loadProfitLoss` /
/// `loadCapitalGains`) with an analogous per-load generation counter.
@Suite("ReportingStore -- recompute race (#1209)")
@MainActor
struct ReportingStoreRecomputeRaceTests {
  @Test
  func staleLoadCategoryBalancesDoesNotClobberFresherResult() async throws {
    let aud = Instrument.defaultTestInstrument
    let repository = GatingAnalysisRepository()
    let store = ReportingStore(
      transactionRepository: FailingTransactionRepository(),
      analysisRepository: repository,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: aud
    )

    let staleResult = CategoryBalancesByType(
      income: [:], expense: [:],
      incomeUncategorised: InstrumentAmount(quantity: 1, instrument: aud),
      expenseUncategorised: nil)
    let freshResult = CategoryBalancesByType(
      income: [:], expense: [:],
      incomeUncategorised: InstrumentAmount(quantity: 999, instrument: aud),
      expenseUncategorised: nil)

    let dateRange = Date().addingTimeInterval(-86_400)...Date()

    // Start a stale load that captures generation N, reads (well, is fed)
    // the stale result, and suspends before publishing.
    repository.setResult(staleResult)
    repository.armGate()
    let staleLoad = Task { @MainActor in
      await store.loadCategoryBalances(dateRange: dateRange)
    }
    await repository.waitUntilGateReached()

    // A fresher load runs to completion while the stale one is suspended —
    // this bumps the generation counter past what the stale load captured.
    repository.setResult(freshResult)
    await store.loadCategoryBalances(dateRange: dateRange)
    #expect(store.incomeUncategorised?.quantity == 999)

    // Release the stale load. Its now-outdated publish must be dropped, not
    // clobber the fresh 999 result back to 1.
    repository.releaseGate()
    await staleLoad.value

    #expect(store.incomeUncategorised?.quantity == 999)
    #expect(!store.isLoadingCategoryBalances)
    #expect(store.categoryBalancesError == nil)
  }
}
