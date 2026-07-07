import Foundation
import GRDB
import Testing

@testable import Moolah

// swiftlint:disable attributes

@Suite("ReportingStore tax transfer-chain regressions")
struct ReportingStoreTaxTransferChainTests {
  private let aud = Instrument.fiat(code: "AUD")

  @Test @MainActor func loadCapitalGains_marksUnavailableAfterSameDayTransferChain()
    async throws
  {
    let context = try await makeBackendContext()
    let secondAccount = Account(
      id: UUID(), name: "Second Brokerage", type: .bank, instrument: .defaultTestInstrument)
    let thirdAccount = Account(
      id: UUID(), name: "Third Brokerage", type: .bank, instrument: .defaultTestInstrument)
    TestBackend.seed(accounts: [secondAccount, thirdAccount], in: context.database)
    TestBackend.seed(
      transactions: try sameDayTransferChainTransactions(
        context: context,
        secondAccount: secondAccount,
        thirdAccount: thirdAccount),
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

  private func sameDayTransferChainTransactions(
    context: ReportingStoreTaxBackendContext,
    secondAccount: Account,
    thirdAccount: Account
  ) throws -> [Transaction] {
    let failedSwapDate = try date(year: 2025, month: 5, day: 1)
    let transferDate = try date(year: 2025, month: 8, day: 1)
    let sellDate = try date(year: 2026, month: 5, day: 1)
    return [
      failedSwap(context: context, date: failedSwapDate),
      transfer(
        context.bhp,
        from: context.account,
        to: secondAccount,
        date: transferDate),
      transfer(
        context.bhp,
        from: secondAccount,
        to: thirdAccount,
        date: transferDate),
      reportingStoreSell(
        instrument: context.bhp,
        quantity: 1,
        proceeds: 5_000,
        date: sellDate,
        in: context,
        account: thirdAccount),
    ]
  }

  private func failedSwap(context: ReportingStoreTaxBackendContext, date: Date) -> Transaction {
    Transaction(
      date: date,
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
      ])
  }

  private func transfer(
    _ instrument: Instrument,
    from source: Account,
    to destination: Account,
    date: Date
  ) -> Transaction {
    Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: source.id,
          instrument: instrument,
          quantity: -1,
          type: .transfer),
        TransactionLeg(
          accountId: destination.id,
          instrument: instrument,
          quantity: 1,
          type: .transfer),
      ])
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

  private func date(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      Calendar.utc.date(from: DateComponents(year: year, month: month, day: day)))
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
