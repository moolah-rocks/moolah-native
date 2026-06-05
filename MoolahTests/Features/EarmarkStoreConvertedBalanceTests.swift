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
      repository: backend.earmarks, conversionService: FixedConversionService(),
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
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    try await store.waitForNextEmission(
      matching: { $0.convertedTotalBalance?.quantity == 500 },
      description: "converted total balance computed"
    )

    #expect(store.convertedTotalBalance?.quantity == 500)
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
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    try await store.waitForNextEmission(
      matching: { $0.convertedTotalBalance?.quantity == 500 },
      description: "converted balances computed"
    )

    // Individual balances should reflect true values
    #expect(store.convertedBalance(for: positiveId)?.quantity == 500)
    #expect(store.convertedBalance(for: negativeId)?.quantity == -18950)

    // Total should clamp negative earmarks to 0, so total = 500 (not 500 - 18950)
    #expect(store.convertedTotalBalance?.quantity == 500)
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
      repository: backend.earmarks, conversionService: FixedConversionService(),
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

    #expect(store.convertedTotalBalance?.quantity == 400)
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
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    try await store.waitForNextEmission(
      matching: { $0.convertedBalance(for: earmarkId)?.quantity == 500 },
      description: "converted balance computed"
    )

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 500)
    #expect(store.convertedSaved(for: earmarkId)?.quantity == 500)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 0)
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
      repository: backend.earmarks, conversionService: FixedConversionService(),
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

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 400)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 100)
  }
}
