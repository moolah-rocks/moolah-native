import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore/InvestmentValues")
@MainActor
struct AccountStoreInvestmentValuesTests {

  // MARK: - Preload investment values on load

  @Test(
    "first emission populates investmentValues from latest repository value for investment accounts"
  )
  func loadPreloadsLatestInvestmentValues() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Brokerage", type: .investment, balance: Decimal(100000) / 100,
      in: database)
    let latestDate = Date()
    let olderDate = try #require(Calendar.current.date(byAdding: .day, value: -7, to: latestDate))
    TestBackend.seed(
      investmentValues: [
        acctId: [
          InvestmentValue(
            date: latestDate,
            value: InstrumentAmount(quantity: Decimal(250000) / 100, instrument: instrument)),
          InvestmentValue(
            date: olderDate,
            value: InstrumentAmount(quantity: Decimal(180000) / 100, instrument: instrument)),
        ]
      ],
      in: database,
      instrument: instrument)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: instrument,
      investmentRepository: backend.investments)

    await expectEventually("latest investment value preloads into value and balance") {
      store.investmentValues[acctId]?.quantity == Decimal(250000) / 100
        && store.convertedBalances[acctId]?.quantity == Decimal(250000) / 100
    }
  }

  @Test("first emission with recordedValue and no snapshot yields zero balance")
  func loadRecordedValueWithoutSnapshotYieldsZero() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Brokerage", type: .investment, balance: Decimal(100000) / 100,
      in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      investmentRepository: backend.investments)

    // `recordedValue` (default) + no snapshot → balance = 0. Position sum is
    // intentionally not used as a fallback; see `displayBalance` in
    // `AccountBalanceCalculator`.
    await expectEventually("balance settles to zero with no investment value") {
      store.investmentValues[acctId] == nil
        && store.convertedBalances[acctId]?.quantity == 0
    }
  }

  @Test("first emission with calculatedFromTrades sums positions when no snapshot exists")
  func loadCalculatedFromTradesUsesPositionsWhenSnapshotMissing() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Brokerage", type: .investment, balance: Decimal(100000) / 100,
      valuationMode: .calculatedFromTrades, in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument,
      investmentRepository: backend.investments)

    await expectEventually("position-derived balance settles, no recorded value") {
      store.investmentValues[acctId] == nil
        && store.convertedBalances[acctId]?.quantity == Decimal(100000) / 100
    }
  }

  // MARK: - updateInvestmentValue

  @Test
  func testUpdateInvestmentValueSetsValue() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "seeded account observed"
    )

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)

    let account = try #require(store.accounts.first)
    await store.updateInvestmentValue(accountId: account.id, value: newValue)
    await expectEventually("investment value and display balance settle to newValue") {
      let balance = try? await store.displayBalance(for: account.id)
      return store.investmentValues[account.id] == newValue && balance == newValue
    }
  }

  @Test
  func testUpdateInvestmentValueClearsValue() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "seeded account observed"
    )

    let account = try #require(store.accounts.first)
    let investmentValue = InstrumentAmount(
      quantity: Decimal(200000) / 100, instrument: Instrument.defaultTestInstrument)
    await store.updateInvestmentValue(accountId: account.id, value: investmentValue)
    await store.updateInvestmentValue(accountId: account.id, value: nil)

    // recordedValue (default) + cleared snapshot → balance = 0 (no fallback to
    // positions). The position sum would be 1000.00 if the account were in
    // calculatedFromTrades mode; see `loadCalculatedFromTradesUsesPositionsWhenSnapshotMissing`.
    await expectEventually("cleared value settles to nil and zero balance") {
      let balance = try? await store.displayBalance(for: account.id)
      return store.investmentValues[account.id] == nil
        && balance == .zero(instrument: .defaultTestInstrument)
    }
  }

  @Test
  func testUpdateInvestmentValueIgnoresUnknownAccount() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "seeded account observed"
    )

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    await store.updateInvestmentValue(accountId: UUID(), value: newValue)

    // Should not affect existing accounts.
    await expectEventually("unknown-account update leaves state untouched") {
      store.accounts.count == 1 && store.investmentValues.isEmpty
    }
  }

  // MARK: - Display Balance

  @Test
  func testDisplayBalanceReturnsInvestmentValueForInvestmentAccount() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Invest", type: .investment, balance: Decimal(100000) / 100,
      in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: acctId) != nil },
      description: "seeded account observed"
    )

    let investmentValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    await store.updateInvestmentValue(accountId: acctId, value: investmentValue)

    await expectEventually("display balance settles to the investment value") {
      let balance = try? await store.displayBalance(for: acctId)
      return balance == investmentValue
    }
  }

  @Test
  func testCanDeleteReturnsTrueForZeroPositions() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(id: acctId, name: "Empty", in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    await expectEventually("seeded empty account can be deleted") {
      store.canDelete(acctId)
    }
  }

  @Test
  func testCanDeleteReturnsFalseForNonZeroPositions() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Active", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    await expectEventually("account with positions cannot be deleted") {
      store.accounts.by(id: acctId)?.positions.isEmpty == false && !store.canDelete(acctId)
    }
  }
}
