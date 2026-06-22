import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore/ApplyDelta")
@MainActor
struct AccountStoreApplyDeltaTests {

  // MARK: - applyDelta

  @Test
  func testApplyDeltaReducesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: acctId) != nil },
      description: "seeded account is observed"
    )

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    await expectEventually("balance settles to reduced amount") {
      let balance = try? await store.displayBalance(for: acctId)
      return balance?.quantity == Decimal(95000) / 100
    }
  }

  @Test
  func testApplyDeltaIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: acctId) != nil },
      description: "seeded account is observed"
    )

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(50000) / 100]]
    await store.applyDelta(deltas)

    await expectEventually("balance settles to increased amount") {
      let balance = try? await store.displayBalance(for: acctId)
      return balance?.quantity == Decimal(150000) / 100
    }
  }

  @Test
  func testApplyDeltaUpdatesBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: checkingId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      id: savingsId, name: "Savings", balance: Decimal(200000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 2 },
      description: "both accounts are observed"
    )

    let deltas: PositionDeltas = [
      checkingId: [instrument: Decimal(-10000) / 100],
      savingsId: [instrument: Decimal(10000) / 100],
    ]
    await store.applyDelta(deltas)

    await expectEventually("both account balances settle to deltas") {
      let checking = try? await store.displayBalance(for: checkingId)
      let savings = try? await store.displayBalance(for: savingsId)
      return checking?.quantity == Decimal(90000) / 100
        && savings?.quantity == Decimal(210000) / 100
    }
  }

  @Test
  func testApplyDeltaUpdatesTotals() async throws {
    let checkingId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: checkingId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.convertedCurrentTotal?.quantity == Decimal(100000) / 100 },
      description: "totals settle"
    )

    let deltas: PositionDeltas = [checkingId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    await expectEventually("totals settle to post-delta amount") {
      store.convertedCurrentTotal?.quantity == Decimal(95000) / 100
        && store.convertedNetWorth?.quantity == Decimal(95000) / 100
    }
  }

  @Test
  func testApplyDeltaViaBalanceDeltaCalculator() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: acctId) != nil },
      description: "seeded account is observed"
    )

    let transaction = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: instrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: transaction)
    await store.applyDelta(delta.accountDeltas)

    await expectEventually("balance settles after calculator-derived delta") {
      let balance = try? await store.displayBalance(for: acctId)
      return balance?.quantity == Decimal(95000) / 100
    }
  }

  @Test
  func testApplyDeltaIgnoresUnknownAccount() async throws {
    let acctId = UUID()
    let unknownId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: acctId) != nil },
      description: "seeded account is observed"
    )

    let deltas: PositionDeltas = [unknownId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    // Balance should be unchanged.
    await expectEventually("known account balance stays unchanged") {
      let balance = try? await store.displayBalance(for: acctId)
      return balance?.quantity == Decimal(100000) / 100
    }
  }

  // MARK: - Converted Totals

  @Test
  func testConvertedTotalsAreNilBeforeFirstEmission() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: Instrument.defaultTestInstrument
    )

    // Read state synchronously before any emission has had a chance to
    // arrive: the @Observable defaults are still in place.
    #expect(store.convertedCurrentTotal == nil)
    #expect(store.convertedInvestmentTotal == nil)
    #expect(store.convertedNetWorth == nil)
  }

  @Test
  func testConvertedTotalsPopulatedAfterEmission() async throws {
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: instrument
    )

    await expectEventually("totals populate after first emission") {
      store.convertedCurrentTotal?.quantity == Decimal(100000) / 100
        && store.convertedNetWorth != nil
    }
  }

  @Test
  func testConvertedTotalsUpdateAfterApplyDelta() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: instrument
    )

    try await store.waitForNextEmission(
      matching: { $0.convertedCurrentTotal?.quantity == Decimal(100000) / 100 },
      description: "totals settle"
    )

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    await expectEventually("totals update after applyDelta") {
      store.convertedCurrentTotal?.quantity == Decimal(95000) / 100
        && store.convertedNetWorth?.quantity == Decimal(95000) / 100
    }
  }
}
