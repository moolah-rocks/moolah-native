import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- applyDelta")
@MainActor
struct EarmarkStoreApplyDeltaTests {
  @Test
  func testApplyDeltaAdjustsPositionsAndBalance() async throws {
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
      matching: { $0.earmarks.by(id: earmarkId) != nil },
      description: "seeded earmark observed"
    )

    await store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 400)
    #expect(store.earmarks.by(id: earmarkId)?.savedPositions.first?.quantity == 500)
    #expect(store.earmarks.by(id: earmarkId)?.spentPositions.first?.quantity == 100)
  }

  @Test
  func testApplyDeltaWithSavedIncreasesBalance() async throws {
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
      matching: { $0.earmarks.by(id: earmarkId) != nil },
      description: "seeded earmark observed"
    )

    await store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: 200]],
      savedDeltas: [earmarkId: [instrument: 200]],
      spentDeltas: [:]
    )

    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 700)
    #expect(store.earmarks.by(id: earmarkId)?.savedPositions.first?.quantity == 700)
  }

  @Test
  func testApplyDeltaAffectsMultipleEarmarks() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
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
        Earmark(id: earmark1Id, name: "Holiday", instrument: instrument),
        Earmark(id: earmark2Id, name: "Car", instrument: instrument),
      ],
      amounts: [
        earmark1Id: (saved: 500, spent: 0),
        earmark2Id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 2 },
      description: "both seeded earmarks observed"
    )

    await store.applyDelta(
      earmarkDeltas: [
        earmark1Id: [instrument: -100],
        earmark2Id: [instrument: 50],
      ],
      savedDeltas: [earmark2Id: [instrument: 50]],
      spentDeltas: [earmark1Id: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmark1Id)?.positions.first?.quantity == 400)
    #expect(store.earmarks.by(id: earmark1Id)?.spentPositions.first?.quantity == 100)
    #expect(store.earmarks.by(id: earmark2Id)?.positions.first?.quantity == 350)
    #expect(store.earmarks.by(id: earmark2Id)?.savedPositions.first?.quantity == 350)
  }
}
