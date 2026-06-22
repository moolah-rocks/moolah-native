import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Create/Update/Hide")
@MainActor
struct EarmarkStoreMutationTests {
  @Test
  func testCreateAddsEarmark() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let earmark = Earmark(name: "New Fund", instrument: .defaultTestInstrument)
    let created = await store.create(earmark)

    #expect(created != nil)
    #expect(created?.name == "New Fund")
    await expectEventually("created earmark observed") {
      store.earmarks.count == 1 && store.earmarks.first?.name == "New Fund"
    }
  }

  @Test
  func testCreateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(),
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    let result = await store.create(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test
  func testCreateReloadsAfterSuccess() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let first = Earmark(name: "First", instrument: .defaultTestInstrument)
    _ = await store.create(first)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument)
    _ = await store.create(second)

    await expectEventually("both created earmarks observed") {
      store.earmarks.by(id: first.id) != nil && store.earmarks.by(id: second.id) != nil
    }
  }

  @Test
  func testUpdateModifiesEarmark() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: earmark.id) != nil },
      description: "seeded earmark observed"
    )

    var modified = earmark
    modified.name = "Vacation Fund"
    let updated = await store.update(modified)

    #expect(updated != nil)
    #expect(updated?.name == "Vacation Fund")
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: earmark.id)?.name == "Vacation Fund" },
      description: "renamed earmark observed"
    )
  }

  @Test
  func testUpdateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(),
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)

    let result = await store.update(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test
  func testHideMarksEarmarkHidden() async throws {
    let earmark = Earmark(name: "Vacation", instrument: .defaultTestInstrument)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.by(id: earmark.id) != nil },
      description: "seeded earmark observed"
    )

    let result = await store.hide(earmark)

    #expect(result?.isHidden == true)
    await expectEventually("hidden flag propagates and removes the earmark from the visible list") {
      store.earmarks.by(id: earmark.id)?.isHidden == true
        && store.visibleEarmarks.contains(where: { $0.id == earmark.id }) == false
    }
  }
}

// MARK: - Test helpers

private struct FailingEarmarkRepository: EarmarkRepository {
  func fetchAll() async throws -> [Earmark] {
    throw BackendError.networkUnavailable
  }

  // No-op stubs for the reactive surface — mutation tests construct a
  // store with this repository specifically to exercise mutation
  // failures, not observation. An empty (immediately-finished) stream
  // satisfies the protocol without delivering any data.
  func observeAll() -> AsyncStream<[Earmark]> {
    AsyncStream { $0.finish() }
  }

  func observeBudget(earmarkId: UUID) -> AsyncStream<[EarmarkBudgetItem]> {
    AsyncStream { $0.finish() }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    throw BackendError.networkUnavailable
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    throw BackendError.networkUnavailable
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    throw BackendError.networkUnavailable
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {
    throw BackendError.networkUnavailable
  }
}
