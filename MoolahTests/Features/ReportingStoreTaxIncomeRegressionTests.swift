import Foundation
import Testing

@testable import Moolah

@Suite("ReportingStore tax income regressions")
struct ReportingStoreTaxIncomeRegressionTests {
  private let aud = Instrument.fiat(code: "AUD")

  @Test("rollups preserve availability independently by tax metric")
  @MainActor
  func rollupPreservesAvailabilityByMetric() throws {
    let summaries = [
      TaxIncomeExpenseSummary(
        ownerId: UUID(),
        taxableIncome: InstrumentAmount(quantity: 100, instrument: aud),
        deductibleExpenses: InstrumentAmount(quantity: 25, instrument: aud),
        deductionsHasUnavailableData: true),
      TaxIncomeExpenseSummary(
        ownerId: UUID(),
        taxableIncome: InstrumentAmount(quantity: 50, instrument: aud),
        deductibleExpenses: InstrumentAmount(quantity: 10, instrument: aud)),
    ]

    let rollup = try #require(
      ReportingStore.taxIncomeExpenseRollup(from: summaries, instrument: aud))

    #expect(rollup.taxableIncome.quantity == 150)
    #expect(rollup.deductibleExpenses.quantity == 35)
    #expect(rollup.incomeHasUnavailableData == false)
    #expect(rollup.deductionsHasUnavailableData)
    #expect(rollup.netHasUnavailableData)
  }

  @Test
  @MainActor
  func loadTaxReport_scopesTaxIncomeFailureAwayFromCapitalGains()
    async throws
  {
    let context = try await makeBackendContext()
    let buyDate = try australianDate(year: 2025, month: 8, day: 1)
    let sellDate = try australianDate(year: 2026, month: 5, day: 1)
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp,
          quantity: 100,
          cost: 4_000,
          date: buyDate,
          in: context),
        reportingStoreSell(
          instrument: context.bhp,
          quantity: 100,
          proceeds: 5_000,
          date: sellDate,
          in: context),
      ],
      in: context.database)
    let service = FakeConversionService.fixedRates([:])
    let store = ReportingStore(
      analysisRepository: ThrowingTaxIncomeAnalysisRepository(),
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadTaxReport(financialYear: 2026)

    #expect(store.error == nil)
    #expect(store.taxIncomeExpenseError != nil)
    #expect(store.taxIncomeExpenseSummaries.isEmpty)
    #expect(store.capitalGainsSummary?.totalGain == 1_000)
    #expect(store.capitalGainsSummary?.eventCount == 1)
  }

  @MainActor
  private func makeLedger(
    _ repository: any TransactionRepository, _ service: any InstrumentConversionService
  ) -> HoldingsCostLedgerStore {
    HoldingsCostLedgerStore(
      transactionRepository: repository, conversionService: service, referenceCurrency: aud)
  }

  private func makeDefaultsWithMigrationComplete() throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: "reporting-tax-\(UUID().uuidString)"))
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)
    return defaults
  }

  private func australianDate(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: year, month: month, day: day)))
  }

  @MainActor
  private func makeBackendContext() async throws -> ReportingStoreTaxBackendContext {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    TestBackend.seed(accounts: [account], in: database)
    try await TestBackend.register(bhp, in: backend)
    return ReportingStoreTaxBackendContext(
      backend: backend, database: database, account: account, bhp: bhp, spam: .AUD)
  }
}

private struct TaxIncomeFailure: LocalizedError {
  var errorDescription: String? {
    "Tax income unavailable"
  }
}

private struct ThrowingTaxIncomeAnalysisRepository: AnalysisRepository {
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

  func fetchTaxIncomeExpenseSummaries(
    dateInterval: Range<Date>,
    targetInstrument: Instrument,
    defaultTaxOwnerId: UUID
  ) async throws -> [TaxIncomeExpenseSummary] {
    throw TaxIncomeFailure()
  }
}
