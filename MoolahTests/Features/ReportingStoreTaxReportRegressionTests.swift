import Foundation
import GRDB
import Testing

@testable import Moolah

// swiftlint:disable attributes

@Suite("ReportingStore tax report regressions")
struct ReportingStoreTaxReportRegressionTests {
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

  private func date(year: Int, month: Int, day: Int, hour: Int = 0) throws -> Date {
    try #require(
      Calendar.utc.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }

  private func australianDate(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: year, month: month, day: day)))
  }

  @Test @MainActor func loadCapitalGains_keepsUnavailableCostBasisScopedToAccount()
    async throws
  {
    let context = try await makeBackendContext()
    let secondAccount = Account(
      id: UUID(), name: "Second Brokerage", type: .bank, instrument: .defaultTestInstrument)
    let failedSwapDate = try date(year: 2025, month: 5, day: 1)
    let buyDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    TestBackend.seed(accounts: [secondAccount], in: context.database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: failedSwapDate,
          legs: [
            TransactionLeg(
              accountId: context.account.id,
              instrument: context.spam,
              quantity: -10,
              type: .trade),
            TransactionLeg(
              accountId: context.account.id,
              instrument: context.bhp,
              quantity: 1,
              type: .trade),
          ]),
        reportingStoreBuy(
          instrument: context.bhp,
          quantity: 100,
          cost: 4_000,
          date: buyDate,
          in: context,
          account: secondAccount),
        reportingStoreSell(
          instrument: context.bhp,
          quantity: 100,
          proceeds: 5_000,
          date: sellDate,
          in: context,
          account: secondAccount),
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

  @Test @MainActor func loadCapitalGains_marksUnavailableAfterAffectedTransfer()
    async throws
  {
    let context = try await makeBackendContext()
    let secondAccount = Account(
      id: UUID(), name: "Second Brokerage", type: .bank, instrument: .defaultTestInstrument)
    let failedSwapDate = try date(year: 2025, month: 5, day: 1)
    let transferDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    TestBackend.seed(accounts: [secondAccount], in: context.database)
    TestBackend.seed(
      transactions: affectedTransferTransactions(
        context: context,
        secondAccount: secondAccount,
        failedSwapDate: failedSwapDate,
        transferDate: transferDate,
        sellDate: sellDate),
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
    #expect(store.capitalGainsUnavailableInstruments == [context.bhp])
  }

  private func affectedTransferTransactions(
    context: ReportingStoreTaxBackendContext,
    secondAccount: Account,
    failedSwapDate: Date,
    transferDate: Date,
    sellDate: Date
  ) -> [Transaction] {
    [
      Transaction(
        date: failedSwapDate,
        legs: [
          TransactionLeg(
            accountId: context.account.id,
            instrument: context.spam,
            quantity: -10,
            type: .trade),
          TransactionLeg(
            accountId: context.account.id,
            instrument: context.bhp,
            quantity: 1,
            type: .trade),
        ]),
      Transaction(
        date: transferDate,
        legs: [
          TransactionLeg(
            accountId: context.account.id,
            instrument: context.bhp,
            quantity: -1,
            type: .transfer),
          TransactionLeg(
            accountId: secondAccount.id,
            instrument: context.bhp,
            quantity: 1,
            type: .transfer),
        ]),
      reportingStoreSell(
        instrument: context.bhp,
        quantity: 1,
        proceeds: 5_000,
        date: sellDate,
        in: context,
        account: secondAccount),
    ]
  }

  @Test @MainActor func loadTaxReport_currentFinancialYearExcludesFutureSales()
    async throws
  {
    let context = try await makeBackendContext()
    let today = try australianDate(year: 2026, month: 7, day: 7)
    let todayPriceDate = try date(year: 2026, month: 7, day: 7, hour: 12)
    let buyDate = try australianDate(year: 2026, month: 7, day: 2)
    let realisedSaleDate = try australianDate(year: 2026, month: 7, day: 5)
    let futureSaleDate = try australianDate(year: 2026, month: 8, day: 1)
    let service = FakeConversionService.dateRates([
      todayPriceDate: [context.bhp.id: 50]
    ])
    TestBackend.seed(
      transactions: [
        reportingStoreBuy(
          instrument: context.bhp,
          quantity: 200,
          cost: 8_000,
          date: buyDate,
          in: context),
        reportingStoreSell(
          instrument: context.bhp,
          quantity: 100,
          proceeds: 5_000,
          date: realisedSaleDate,
          in: context),
        reportingStoreSell(
          instrument: context.bhp,
          quantity: 100,
          proceeds: 7_000,
          date: futureSaleDate,
          in: context),
      ],
      in: context.database)
    let store = ReportingStore(
      conversionService: service,
      profileCurrency: aud,
      holdingsCostLedger: makeLedger(context.backend.transactions, service),
      userDefaults: try makeDefaultsWithMigrationComplete())

    await store.loadTaxReport(financialYear: 2027, today: today)

    #expect(store.error == nil)
    #expect(store.capitalGainsSummary?.totalGain == 1_000)
    #expect(store.capitalGainsSummary?.eventCount == 1)
    #expect(store.profitLoss.first?.currentQuantity == 100)
  }

  @MainActor
  private func makeBackendContext() async throws -> ReportingStoreTaxBackendContext {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument)
    let spam = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x21841eb46ccce03ebe57b4ee6eb547f31dfde152",
      symbol: "SPAM",
      name: "Spam Token",
      decimals: 18)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    TestBackend.seed(accounts: [account], in: database)
    try await TestBackend.register(bhp, in: backend)
    try await TestBackend.register(spam, in: backend)
    return ReportingStoreTaxBackendContext(
      backend: backend, database: database, account: account, bhp: bhp, spam: spam)
  }
}

// swiftlint:enable attributes
