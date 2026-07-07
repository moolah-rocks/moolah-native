import Foundation
import GRDB
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes type_body_length

@Suite("ReportingStore tax filtering")
struct ReportingStoreTaxFilteringTests {
  private let aud = Instrument.fiat(code: "AUD")

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

  private func makeInstruments() -> (bhp: Instrument, spam: Instrument) {
    let spam = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x21841eb46ccce03ebe57b4ee6eb547f31dfde152",
      symbol: "SPAM",
      name: "Spam Token",
      decimals: 18)
    return (Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"), spam)
  }

  private func date(year: Int, month: Int, day: Int) throws -> Date {
    try #require(Calendar.utc.date(from: DateComponents(year: year, month: month, day: day)))
  }

  private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0
  ) throws -> Date {
    try #require(
      Calendar.utc.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
  }

  private func australianDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0
  ) throws -> Date {
    try #require(
      AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
  }

  @Test @MainActor func loadProfitLoss_usesAsOfDateAndExcludesSpamInstruments() async throws {
    let fixture = try await makeProfitLossFixture()
    let service = FakeConversionService.dateRates([
      fixture.eofy: [fixture.bhp.id: 50, fixture.spam.id: 10],
      fixture.later: [fixture.bhp.id: 70, fixture.spam.id: 20],
    ])
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(fixture.backend.transactions, service))

    await store.loadProfitLoss(asOfDate: fixture.eofy, excluding: [fixture.spam])

    #expect(store.error == nil)
    #expect(store.profitLoss.map { $0.instrument } == [fixture.bhp])
    #expect(store.profitLoss.first?.currentValue == 5_000)
    #expect(store.profitLoss.first?.unrealizedGain == 1_000)
  }

  @Test @MainActor func loadCapitalGains_excludesSpamInstrumentsFromRowsAndSummary()
    async throws
  {
    let fixture = try await makeCapitalGainsFixture()
    let service = FakeConversionService.fixedRates([:])
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(fixture.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadCapitalGains(financialYear: 2026, excluding: [fixture.spam])

    #expect(store.error == nil)
    #expect(store.capitalGainsResult?.events.map(\.instrument) == [fixture.bhp])
    #expect(store.capitalGainsSummary?.totalGain == 1_000)
    #expect(store.capitalGainsSummary?.eventCount == 1)
  }

  @Test @MainActor func loadCapitalGains_ignoresUnavailableUnrelatedInstrument()
    async throws
  {
    let context = try await makeBackendContext()
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    let failingDate = try date(year: 2025, month: 9, day: 1)
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreSell(
          instrument: context.bhp, quantity: 100, proceeds: 5_000, date: sellDate, in: context),
        reportingStoreIncome(
          instrument: context.spam, quantity: 10, date: failingDate, in: context),
      ],
      in: context.database)
    let service = FakeConversionService.failingInstruments([context.spam.id])
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadCapitalGains(financialYear: 2026)

    #expect(store.error == nil)
    #expect(store.capitalGainsHasUnavailableData == false)
    #expect(store.capitalGainsUnavailableInstruments.isEmpty)
    #expect(store.capitalGainsSummary?.totalGain == 1_000)
  }

  @Test @MainActor func loadCapitalGains_marksFailedDisposalInYearUnavailable()
    async throws
  {
    let context = try await makeBackendContext()
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreSell(
          instrument: context.bhp, quantity: 100, proceeds: 5_000, date: sellDate, in: context),
        reportingStoreSpend(instrument: context.spam, quantity: 10, date: sellDate, in: context),
      ],
      in: context.database)
    let service = FakeConversionService.failingInstruments([context.spam.id])
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadCapitalGains(financialYear: 2026)

    #expect(store.error == nil)
    #expect(store.capitalGainsHasUnavailableData)
    #expect(store.capitalGainsUnavailableInstruments == [context.spam])
    #expect(store.capitalGainsSummary?.totalGain == 1_000)
  }

  @Test @MainActor func loadCapitalGains_marksPriorFailedCostBasisInputUnavailable()
    async throws
  {
    let context = try await makeBackendContext()
    let priorBuyDate = try date(year: 2025, month: 5, day: 1)
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    TestBackend.seed(
      transactions: [
        reportingStoreIncome(
          instrument: context.spam, quantity: 10, date: priorBuyDate, in: context),
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreSell(
          instrument: context.bhp, quantity: 100, proceeds: 5_000, date: sellDate, in: context),
        reportingStoreSell(
          instrument: context.spam, quantity: 10, proceeds: 1_000, date: sellDate, in: context),
      ],
      in: context.database)
    let service = FakeConversionService.failingInstruments([context.spam.id])
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadCapitalGains(financialYear: 2026)

    #expect(store.error == nil)
    #expect(store.capitalGainsHasUnavailableData)
    #expect(store.capitalGainsUnavailableInstruments == [context.spam])
    #expect(store.capitalGainsSummary?.totalGain == 1_000)
  }

  @Test @MainActor func loadTaxReport_includesFinalDayHoldingsButExcludesNextYear()
    async throws
  {
    let context = try await makeBackendContext()
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let finalDay = try australianDate(year: 2026, month: 6, day: 30, hour: 23)
    let nextYearStart = try australianDate(year: 2026, month: 7, day: 1)
    let priorUtcDate = try date(year: 2026, month: 6, day: 29)
    let valuationDate = try date(year: 2026, month: 6, day: 30, hour: 12)
    let service = FakeConversionService.dateRates([
      priorUtcDate: [context.bhp.id: 10],
      valuationDate: [context.bhp.id: 50],
    ])
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreBuy(
          instrument: context.bhp, quantity: 1, cost: 40, date: finalDay, in: context),
        reportingStoreBuy(
          instrument: context.bhp, quantity: 10, cost: 400, date: nextYearStart, in: context),
      ],
      in: context.database)
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadTaxReport(financialYear: 2026)

    #expect(store.error == nil)
    let expectedHoldingsDate = try australianDate(year: 2026, month: 6, day: 30)
    #expect(store.taxReportHoldingsDate == expectedHoldingsDate)
    #expect(store.profitLoss.first?.currentQuantity == 101)
    #expect(store.profitLoss.first?.currentValue == 5_050)
    #expect(
      service.recordedCalls.contains {
        $0.from == context.bhp && $0.to == aud && $0.date == valuationDate
      })
  }

  @Test @MainActor func loadTaxReport_currentFinancialYearUsesTodayNotFutureYearEnd()
    async throws
  {
    let context = try await makeBackendContext()
    let today = try australianDate(year: 2026, month: 7, day: 7)
    let todayPriceDate = try date(year: 2026, month: 7, day: 7, hour: 12)
    let buyDate = try australianDate(year: 2026, month: 7, day: 2)
    let futureBuyDate = try australianDate(year: 2026, month: 8, day: 1)
    let futureYearEnd = try australianDate(year: 2027, month: 6, day: 30)
    let service = FakeConversionService.dateRates([
      todayPriceDate: [context.bhp.id: 50],
      futureYearEnd: [context.bhp.id: 90],
    ])
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreBuy(
          instrument: context.bhp, quantity: 10, cost: 400, date: futureBuyDate, in: context),
      ],
      in: context.database)
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadTaxReport(financialYear: 2027, today: today)

    #expect(store.error == nil)
    #expect(store.taxReportHoldingsDate == today)
    #expect(store.profitLoss.first?.currentQuantity == 100)
    #expect(store.profitLoss.first?.currentValue == 5_000)
    #expect(
      service.recordedCalls.contains {
        $0.from == context.bhp && $0.to == aud && $0.date == todayPriceDate
      })
  }

  @MainActor
  private func makeProfitLossFixture() async throws -> ReportingStoreProfitLossFixture {
    let context = try await makeBackendContext()
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let eofy = try date(year: 2026, month: 6, day: 30)
    let later = try date(year: 2026, month: 7, day: 1)
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreBuy(
          instrument: context.spam, quantity: 10, cost: 100, date: buyDate, in: context),
        reportingStoreSell(
          instrument: context.bhp, quantity: 50, proceeds: 3_500, date: later, in: context),
      ],
      in: context.database)
    return ReportingStoreProfitLossFixture(context: context, eofy: eofy, later: later)
  }

  @MainActor
  private func makeCapitalGainsFixture() async throws -> ReportingStoreCapitalGainsFixture {
    let context = try await makeBackendContext()
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp, quantity: 100, cost: 4_000, date: buyDate, in: context),
        reportingStoreSell(
          instrument: context.bhp, quantity: 100, proceeds: 5_000, date: sellDate, in: context),
        reportingStoreBuy(
          instrument: context.spam, quantity: 10, cost: 100, date: buyDate, in: context),
        reportingStoreSell(
          instrument: context.spam, quantity: 10, proceeds: 150, date: sellDate, in: context),
      ],
      in: context.database)
    return ReportingStoreCapitalGainsFixture(context: context)
  }

  @MainActor
  private func makeBackendContext() async throws -> ReportingStoreTaxBackendContext {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument)
    let instruments = makeInstruments()
    TestBackend.seed(accounts: [account], in: database)
    try await TestBackend.register(instruments.bhp, in: backend)
    try await TestBackend.register(instruments.spam, in: backend)
    return ReportingStoreTaxBackendContext(
      backend: backend, database: database, account: account,
      bhp: instruments.bhp, spam: instruments.spam)
  }

}

// swiftlint:enable attributes type_body_length
