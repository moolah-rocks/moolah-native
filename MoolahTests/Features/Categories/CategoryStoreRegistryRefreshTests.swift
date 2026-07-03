import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cross-database refresh coverage for the reactive `CategoryStore`.
///
/// An in-app profile import writes the `category` rows through a GRDB
/// connection that the already-open session's `observeAll()` does not observe
/// (the import path and the live session can hold separate `DatabaseQueue`s
/// over the same file). Without the shared instrument-registry backstop the
/// categories list stays stale until an app restart — the gap these tests pin,
/// mirroring `AccountGroupStore` (#1149).
@Suite("CategoryStore registry refresh", .serialized)
@MainActor
struct CategoryStoreRegistryRefreshTests {

  @Test("registry tick refreshes categories written via a separate connection")
  func registryTickRefreshesCategoriesAcrossConnections() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CategoryStoreRegistryRefreshTests-\(UUID().uuidString)")
    try await runCrossConnectionRefresh(in: directory)
    try? FileManager.default.removeItem(at: directory)
  }

  /// Drives the cross-connection refresh and tears down every DB handle before
  /// returning, so the file is closed before the caller deletes it.
  private func runCrossConnectionRefresh(in directory: URL) async throws {
    let url = directory.appendingPathComponent("data.sqlite")
    let sessionQueue = try ProfileDatabase.open(at: url)
    let importQueue = try ProfileDatabase.open(at: url)

    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = CategoryStore(
      repository: GRDBCategoryRepository(database: sessionQueue),
      instrumentChanges: registry)
    try await store.waitForFirstEmission()
    #expect(store.categories.roots.isEmpty)

    // The import writes the category through its own connection; the session's
    // `observeAll()` is blind to it (separate `DatabaseQueue`).
    _ = try await GRDBCategoryRepository(database: importQueue).create(
      Moolah.Category(name: "Imported"))

    // The import fires the shared registry's change stream; the store must
    // re-fetch and surface the category it never observed.
    try await SharedRegistryTestSupport.fireRegistryChange(on: registry)

    await expectEventually("registry tick live-refreshes the imported category") {
      store.categories.roots.count == 1 && store.categories.roots.first?.name == "Imported"
    }

    store.stopObserving()
    await store.awaitObservationTermination()
  }

  @Test("registry change after stopObserving does not refresh the store")
  func registryChangeAfterStopDoesNotRefresh() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = CategoryStore(
      repository: backend.categories, instrumentChanges: registry)
    try await store.waitForFirstEmission()
    await store.drainPendingEmissions()
    store.stopObserving()
    await store.awaitObservationTermination()

    try await SharedRegistryTestSupport.fireRegistryChange(on: registry)

    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("stale instrument-registry refresh does not clobber a fresher categories snapshot")
  func staleRegistryRefreshIsDropped() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = CategoryStore(
      repository: backend.categories, instrumentChanges: registry)
    _ = try await backend.categories.create(Moolah.Category(name: "First"))
    await expectEventually("first category visible") {
      store.categories.roots.contains { $0.name == "First" }
    }

    // The registry path would capture the generation here, before its fetch.
    let observedGeneration = store.snapshotGeneration

    // An authoritative `observeAll()` snapshot lands while the (simulated)
    // stale fetch is in flight, bumping the generation.
    _ = try await backend.categories.create(Moolah.Category(name: "Second"))
    await expectEventually("second category visible") {
      store.categories.roots.contains { $0.name == "Second" }
    }

    // The stale, empty refetch resolves last. It must be dropped, not applied.
    await store.applyInstrumentRegistryRefresh([], observedGeneration: observedGeneration)
    #expect(store.categories.roots.contains { $0.name == "First" })
    #expect(store.categories.roots.contains { $0.name == "Second" })

    store.stopObserving()
  }

  @Test("up-to-date instrument-registry refresh applies")
  func currentRegistryRefreshApplies() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = CategoryStore(
      repository: backend.categories, instrumentChanges: registry)
    let category = try await backend.categories.create(Moolah.Category(name: "Original"))
    await expectEventually("category visible") {
      store.categories.roots.contains { $0.name == "Original" }
    }

    // A refresh tagged with the current generation simulates a fetch that
    // observed the latest snapshot; a renamed copy proves it applied.
    let observedGeneration = store.snapshotGeneration
    let renamed = Moolah.Category(id: category.id, name: "Renamed")
    await store.applyInstrumentRegistryRefresh([renamed], observedGeneration: observedGeneration)
    #expect(store.categories.roots.contains { $0.name == "Renamed" })

    store.stopObserving()
  }
}
