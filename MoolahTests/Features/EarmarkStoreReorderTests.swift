import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Reorder")
@MainActor
struct EarmarkStoreReorderTests {
  @Test
  func testReorderEarmarksUpdatesPositions() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 3 },
      description: "all three earmarks observed"
    )

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    // `reorderEarmarks` issues one `update` per row, so each commit
    // triggers its own observation emission. A names-only predicate can
    // match an intermediate state where positions are not yet all
    // rewritten (two rows briefly share the same position, and the
    // sort-by-position tie-break happens to produce the expected name
    // order). Pin both names AND positions so the poll only settles on
    // the final, fully-rewritten state.
    await expectEventually("reorder settles with final names and positions") {
      let visible = store.visibleEarmarks
      return visible.map(\.name) == ["Third", "First", "Second"]
        && visible.map(\.position) == [0, 1, 2]
    }
  }

  @Test
  func testReorderEarmarksSkipsHiddenEarmarks() async throws {
    let firstVisible = Earmark(name: "Visible1", instrument: .defaultTestInstrument, position: 0)
    let hidden = Earmark(
      name: "Hidden", instrument: .defaultTestInstrument, isHidden: true, position: 1)
    let secondVisible = Earmark(name: "Visible2", instrument: .defaultTestInstrument, position: 2)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [firstVisible, hidden, secondVisible], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 3 },
      description: "all three earmarks observed"
    )

    await store.reorderEarmarks(from: IndexSet(integer: 1), to: 0)

    // Pin both names AND positions so the poll doesn't settle on an
    // intermediate emission where two visible rows briefly share a
    // position (see `testReorderEarmarksUpdatesPositions`). The hidden
    // earmark keeps its original position throughout.
    await expectEventually("visible rows reorder while the hidden earmark stays put") {
      let visible = store.visibleEarmarks
      return visible.map(\.name) == ["Visible2", "Visible1"]
        && visible.map(\.position) == [0, 1]
        && store.earmarks.ordered.first(where: { $0.isHidden })?.position == 1
    }
  }

  @Test
  func testReorderSingleEarmarkIsNoOp() async throws {
    let only = Earmark(name: "Only", instrument: .defaultTestInstrument, position: 0)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [only], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 1 },
      description: "seeded earmark observed"
    )

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].position == 0)
  }

  @Test
  func testReorderEmptyListIsNoOp() async throws {
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.isEmpty)
  }

  @Test
  func testReorderPersistsToRepository() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: database)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 3 },
      description: "all three earmarks observed"
    )

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    let persisted = try await backend.earmarks.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted[0].name == "Third")
    #expect(persisted[1].name == "First")
    #expect(persisted[2].name == "Second")
    #expect(persisted[0].position == 0)
    #expect(persisted[1].position == 1)
    #expect(persisted[2].position == 2)
  }

  @Test
  func testReorderSurfacesErrorOnFailure() async throws {
    let first = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let second = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let third = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: [first, second, third], in: database)
    let failing = UpdateFailingEarmarkRepository(wrapping: backend.earmarks)
    let store = EarmarkStore(
      repository: failing, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 3 },
      description: "all three earmarks observed"
    )

    failing.failUpdates = true
    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    #expect(store.error != nil)
  }
}

// MARK: - Test helpers

/// Wraps a real repository but can be configured to fail `update` calls so
/// tests can exercise error paths without mocking. The reactive
/// `observeAll()` / `observeBudget` / `observeErrors` surface forwards to
/// the wrapped repository so the store sees seeded state; mutation
/// failures still surface from `update(_:)` below.
///
/// `@unchecked Sendable` justification: stored mutation flags are
/// `var`, but tests mutate them only from the main actor before
/// invoking the store action under test. `wrapped` is an immutable
/// reference to a `Sendable` value.
final class UpdateFailingEarmarkRepository: EarmarkRepository, @unchecked Sendable {
  private let wrapped: any EarmarkRepository
  /// When `true`, every `update` call throws immediately.
  var failUpdates: Bool = false
  /// When non-nil, the first `failAfter` calls succeed; subsequent calls
  /// throw. Useful for simulating partial writes.
  var failAfter: Int?
  private var updateCount: Int = 0

  init(wrapping repository: any EarmarkRepository) {
    self.wrapped = repository
  }

  func fetchAll() async throws -> [Earmark] {
    try await wrapped.fetchAll()
  }

  func observeAll() -> AsyncStream<[Earmark]> {
    wrapped.observeAll()
  }

  func observeBudget(earmarkId: UUID) -> AsyncStream<[EarmarkBudgetItem]> {
    wrapped.observeBudget(earmarkId: earmarkId)
  }

  func observeErrors() -> AsyncStream<any Error> {
    wrapped.observeErrors()
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    try await wrapped.create(earmark)
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    if failUpdates {
      throw BackendError.networkUnavailable
    }
    if let threshold = failAfter, updateCount >= threshold {
      throw BackendError.networkUnavailable
    }
    updateCount += 1
    return try await wrapped.update(earmark)
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    try await wrapped.fetchBudget(earmarkId: earmarkId)
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {
    try await wrapped.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: amount)
  }
}
