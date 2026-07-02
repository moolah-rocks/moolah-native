import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes

@Suite("ReportingStore")
struct ReportingStoreTests {
  let aud = Instrument.fiat(code: "AUD")

  /// Returns an isolated `UserDefaults` suite with the unified-identity
  /// migration completion flag pre-set, so capital-gains tests that exercise
  /// the normal happy path are not gated by `isMigratingCrossChainIdentity`.
  private func makeDefaultsWithMigrationComplete() throws -> UserDefaults {
    let suiteName = "reporting-store-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)
    return defaults
  }

  @Test @MainActor func loadProfitLoss_populatesState() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: database)

    let bhp = Instrument(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    try await TestBackend.register(bhp, in: backend)

    let buyTx = Transaction(
      date: Date(),
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .trade),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
      ]
    )
    TestBackend.seed(transactions: [buyTx], in: database)

    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50])
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: service,
      profileCurrency: aud
    )

    await store.loadProfitLoss()

    #expect(!store.isLoading)
    #expect(store.error == nil)
    #expect(store.profitLoss.count == 1)
    #expect(store.profitLoss[0].instrument.id == "ASX:BHP.AX")
    #expect(store.profitLoss[0].totalInvested == 4000)
    #expect(store.profitLoss[0].currentValue == 5000)
    #expect(store.profitLoss[0].unrealizedGain == 1000)
  }

  @Test @MainActor func loadCapitalGains_forFinancialYear() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: database)

    let bhp = Instrument(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    try await TestBackend.register(bhp, in: backend)

    let calendar = Calendar(identifier: .gregorian)
    // Buy in early FY2026 (August 2025)
    let buyDate = try #require(calendar.date(from: DateComponents(year: 2025, month: 8, day: 1)))
    let buyTx = Transaction(
      date: buyDate,
      payee: "Buy BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: -4000, type: .trade),
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
      ]
    )

    // Sell in late FY2026 (May 2026)
    let sellDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
    let sellTx = Transaction(
      date: sellDate,
      payee: "Sell BHP",
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: bhp, quantity: -100, type: .trade),
        TransactionLeg(
          accountId: account.id, instrument: aud, quantity: 5000, type: .trade),
      ]
    )
    TestBackend.seed(transactions: [buyTx, sellTx], in: database)

    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: aud,
      userDefaults: try makeDefaultsWithMigrationComplete()
    )

    await store.loadCapitalGains(financialYear: 2026)

    #expect(!store.isLoading)
    #expect(store.error == nil)
    #expect(store.capitalGainsResult != nil)
    #expect(store.capitalGainsResult?.events.count == 1)
    #expect(store.capitalGainsResult?.totalRealizedGain == 1000)
    #expect(store.capitalGainsSummary != nil)
    #expect(store.capitalGainsSummary?.eventCount == 1)
  }

  @Test @MainActor func capitalGainsSummary_separatesShortAndLongTerm() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .bank, instrument: .defaultTestInstrument
    )
    TestBackend.seed(accounts: [account], in: database)
    let fixture = makeShortAndLongTermGainsFixture(accountId: account.id)
    for instrument in fixture.flatMap(\.legs).map(\.instrument)
    where instrument.kind != .fiatCurrency {
      try await TestBackend.register(instrument, in: backend)
    }
    TestBackend.seed(transactions: fixture, in: database)

    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: aud,
      userDefaults: try makeDefaultsWithMigrationComplete()
    )

    await store.loadCapitalGains(financialYear: 2026)

    let summary = store.capitalGainsSummary
    #expect(summary != nil)
    // BHP: long-term gain = 1000 (5000 - 4000)
    #expect(summary?.longTermGain == 1000)
    // CBA: short-term gain = 1000 (6000 - 5000)
    #expect(summary?.shortTermGain == 1000)
    #expect(summary?.totalGain == 2000)
  }

  /// Two stocks (BHP bought long-term before the window, CBA bought
  /// short-term inside the window) both sold on the same day in FY2026.
  private func makeShortAndLongTermGainsFixture(accountId: UUID) -> [Transaction] {
    let bhp = Instrument(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", decimals: 0,
      ticker: "BHP.AX", exchange: "ASX", chainId: nil, contractAddress: nil)
    let cba = Instrument(
      id: "ASX:CBA.AX", kind: .stock, name: "CBA", decimals: 0,
      ticker: "CBA.AX", exchange: "ASX", chainId: nil, contractAddress: nil)

    let calendar = Calendar(identifier: .gregorian)
    guard
      let buyBHPDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let buyCBADate = calendar.date(from: DateComponents(year: 2025, month: 10, day: 1)),
      let sellDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))
    else { preconditionFailure("static gregorian DateComponents are always valid") }

    return [
      Transaction(
        date: buyBHPDate, payee: "Buy BHP",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: -4000, type: .trade),
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: 100, type: .trade),
        ]),
      Transaction(
        date: buyCBADate, payee: "Buy CBA",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: -5000, type: .trade),
          TransactionLeg(
            accountId: accountId, instrument: cba, quantity: 50, type: .trade),
        ]),
      Transaction(
        date: sellDate, payee: "Sell BHP",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: -100, type: .trade),
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: 5000, type: .trade),
        ]),
      Transaction(
        date: sellDate, payee: "Sell CBA",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: cba, quantity: -50, type: .trade),
          TransactionLeg(
            accountId: accountId, instrument: aud, quantity: 6000, type: .trade),
        ]),
    ]
  }

  @Test func capitalGainsSummary_taxAdjustmentValues() {
    let summary = CapitalGainsSummary(
      shortTermGain: 500,
      longTermGain: 1000,
      totalGain: 1500,
      eventCount: 2
    )

    let values = summary.asTaxAdjustmentValues(currency: aud)
    #expect(values.shortTerm.quantity == 500)
    #expect(values.longTerm.quantity == 1000)
    #expect(values.losses.quantity == 0)
  }
}

// swiftlint:enable attributes
