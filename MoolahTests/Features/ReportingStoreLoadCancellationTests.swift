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

  @Test("cancelled tax income load stops the outer tax report pipeline")
  func cancelledTaxIncomeLoadStopsTaxReportPipeline() async throws {
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
    let repository = GatedTaxIncomeAnalysisRepository(ownerId: UUID())
    let store = ReportingStore(
      analysisRepository: repository,
      conversionService: service,
      profileCurrency: .AUD,
      holdingsCostLedger: HoldingsCostLedgerStore(
        transactionRepository: context.backend.transactions,
        conversionService: service,
        referenceCurrency: .AUD),
      userDefaults: try makeDefaultsWithMigrationComplete())

    let task = Task { @MainActor in
      await store.loadTaxReport(financialYear: 2026)
    }
    await repository.waitUntilFetchStarted()
    task.cancel()
    await repository.releaseFetch()
    await task.value

    #expect(store.taxIncomeExpenseSummaries.isEmpty)
    #expect(store.capitalGainsSummary == nil)
    #expect(!store.isLoading)
  }

  @Test("category owner changes invalidate tax income summaries")
  func categoryOwnerChangesInvalidateTaxIncomeSummaries() async throws {
    let ownerId = UUID()
    let (stream, continuation) = AsyncStream<[Moolah.Category]>.makeStream()
    let store = ReportingStore(
      analysisRepository: ImmediateTaxIncomeAnalysisRepository(ownerId: ownerId),
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: .AUD,
      categoryChanges: stream,
      defaultTaxOwnerId: ownerId)
    await Task.yield()

    await store.loadTaxReport(financialYear: 2026)
    #expect(!store.taxIncomeExpenseSummaries.isEmpty)

    continuation.yield([
      Moolah.Category(name: "Salary", isTaxReportable: true, taxOwnerIds: [ownerId])
    ])
    await Task.yield()
    continuation.yield([
      Moolah.Category(name: "Salary", isTaxReportable: true, taxOwnerIds: [UUID()])
    ])
    try await waitUntil { store.ownerDependentReportInvalidation == 1 }

    #expect(store.taxIncomeExpenseSummaries.isEmpty)
    #expect(store.taxIncomeExpenseDateInterval == nil)
    #expect(!store.isLoading)
  }

  @Test("tax owner changes update labels and invalidate reports")
  func taxOwnerChangesUpdateLabelsAndInvalidateReports() async throws {
    let ownerId = UUID()
    let (stream, continuation) = AsyncStream<[TaxOwner]>.makeStream()
    let repository = StreamTaxOwnerRepository(stream: stream)
    let store = ReportingStore(
      analysisRepository: ImmediateTaxIncomeAnalysisRepository(ownerId: ownerId),
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: .AUD,
      taxOwnerRepository: repository,
      defaultTaxOwnerId: ownerId)
    continuation.yield([TaxOwner(id: ownerId, name: "Alex")])
    try await waitUntil { store.taxOwnerNames[ownerId] == "Alex" }

    await store.loadTaxReport(financialYear: 2026)
    #expect(!store.taxIncomeExpenseSummaries.isEmpty)

    continuation.yield([TaxOwner(id: ownerId, name: "Family Trust", kind: .trust)])
    try await waitUntil { store.ownerDependentReportInvalidation == 1 }

    #expect(store.taxOwnerNames[ownerId] == "Family Trust")
    #expect(store.taxOwnerKinds[ownerId] == .trust)
    #expect(store.taxIncomeExpenseSummaries.isEmpty)
  }

  private func makeDefaultsWithMigrationComplete() throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: "reporting-cancel-\(UUID().uuidString)"))
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)
    return defaults
  }

  private func australianDate(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: year, month: month, day: day)))
  }

  /// Polls the observation task instead of assuming one actor yield drains it.
  /// The full focused suite runs tests concurrently enough that a single yield
  /// can sample before the stream consumer handles the second owner emission.
  private func waitUntil(
    timeout: Duration = .seconds(1),
    pollEvery: Duration = .milliseconds(10),
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: pollEvery)
    }
    if condition() { return }
    throw TimeoutError()
  }

  private struct TimeoutError: Error {}

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
    try Task.checkCancellation()
    return [
      TaxIncomeExpenseSummary(
        ownerId: ownerId,
        taxableIncome: InstrumentAmount(quantity: 100, instrument: targetInstrument),
        deductibleExpenses: InstrumentAmount(quantity: 0, instrument: targetInstrument))
    ]
  }
}

private struct ImmediateTaxIncomeAnalysisRepository: AnalysisRepository {
  let ownerId: UUID

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
    [
      TaxIncomeExpenseSummary(
        ownerId: ownerId,
        taxableIncome: InstrumentAmount(quantity: 100, instrument: targetInstrument),
        deductibleExpenses: InstrumentAmount(quantity: 10, instrument: targetInstrument))
    ]
  }
}

private struct StreamTaxOwnerRepository: TaxOwnerRepository {
  let stream: AsyncStream<[TaxOwner]>

  func fetchAll() async throws -> [TaxOwner] {
    []
  }

  func observeAll() -> AsyncStream<[TaxOwner]> {
    stream
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  func create(_ owner: TaxOwner) async throws -> TaxOwner {
    owner
  }

  func update(_ owner: TaxOwner) async throws -> TaxOwner {
    owner
  }

  func delete(id _: UUID) async throws {}
}
