import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Converted Balances")
@MainActor
struct EarmarkStoreConvertedBalanceTests {
  // MARK: - convertedTotalBalance

  @Test
  func testConvertedTotalBalanceNilBeforeLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    #expect(store.convertedTotalBalance == nil)
  }

  @Test
  func testConvertedTotalBalancePopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    await expectEventually("converted total balance computed") {
      store.convertedTotalBalance?.quantity == 500
    }
  }

  @Test
  func testConvertedTotalBalanceExcludesNegativeEarmarks() async throws {
    let positiveId = UUID()
    let negativeId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(id: positiveId, name: "Holiday Fund", instrument: instrument),
        Earmark(id: negativeId, name: "Investments", instrument: instrument),
      ],
      amounts: [
        positiveId: (saved: 500, spent: 0),
        negativeId: (saved: -18950, spent: 0),
      ],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    // Individual balances should reflect true values; the total should clamp
    // negative earmarks to 0, so total = 500 (not 500 - 18950).
    await expectEventually("balances settle with negative earmark clamped from the total") {
      store.convertedBalance(for: positiveId)?.quantity == 500
        && store.convertedBalance(for: negativeId)?.quantity == -18950
        && store.convertedTotalBalance?.quantity == 500
    }
  }

  @Test
  func testConvertedTotalBalanceUpdatesAfterApplyDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.convertedTotalBalance?.quantity == 500 },
      description: "seeded earmark balance settled"
    )

    await store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    await expectEventually("converted total reflects the applied delta") {
      store.convertedTotalBalance?.quantity == 400
    }
  }

  // MARK: - Per-earmark converted amounts

  @Test
  func testConvertedBalancePerEarmarkPopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    await expectEventually("per-earmark converted balance, saved, and spent settle") {
      store.convertedBalance(for: earmarkId)?.quantity == 500
        && store.convertedSaved(for: earmarkId)?.quantity == 500
        && store.convertedSpent(for: earmarkId)?.quantity == 0
    }
  }

  @Test
  func testConvertedBalancePerEarmarkUpdatesAfterDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.convertedBalance(for: earmarkId)?.quantity == 500 },
      description: "seeded earmark balance settled"
    )

    await store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    await expectEventually("per-earmark balance and spent reflect the applied delta") {
      store.convertedBalance(for: earmarkId)?.quantity == 400
        && store.convertedSpent(for: earmarkId)?.quantity == 100
    }
  }

  // MARK: - displayBalance (authoritative on-demand)

  @Test
  func testDisplayBalanceComputesAuthoritativeBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    // Only wait for the earmark to be observed — `displayBalance` recomputes
    // from positions on demand, so it must not depend on the converted-balance
    // dictionary having settled first.
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: earmarkId) != nil },
      description: "seeded earmark observed"
    )

    let balance = try await store.displayBalance(for: earmarkId)

    #expect(balance.quantity == 500)
    #expect(balance.instrument == instrument)
  }

  @Test
  func testDisplayBalanceReturnsZeroForUnknownEarmark() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    let balance = try await store.displayBalance(for: UUID())

    #expect(balance.quantity == 0)
    #expect(balance.instrument == .defaultTestInstrument)
  }
}
