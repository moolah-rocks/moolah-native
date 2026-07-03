import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cross-database refresh coverage for the reactive `ImportRuleStore`.
///
/// An in-app profile import writes the `import_rule` rows through a GRDB
/// connection that the already-open session's `observeAll()` does not observe.
/// Without the shared instrument-registry backstop the rules list stays stale
/// until an app restart — the gap these tests pin, mirroring `AccountGroupStore`
/// (#1149).
@Suite("ImportRuleStore registry refresh", .serialized)
@MainActor
struct ImportRuleStoreRegistryRefreshTests {

  private func rule(id: UUID = UUID(), name: String, position: Int = 0) -> ImportRule {
    ImportRule(id: id, name: name, position: position, conditions: [], actions: [])
  }

  @Test("registry tick refreshes rules written via a separate connection")
  func registryTickRefreshesRulesAcrossConnections() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImportRuleStoreRegistryRefreshTests-\(UUID().uuidString)")
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
    let store = ImportRuleStore(
      repository: GRDBImportRuleRepository(database: sessionQueue),
      instrumentChanges: registry)
    try await store.waitForFirstEmission()
    #expect(store.rules.isEmpty)

    // The import writes the rule through its own connection; the session's
    // `observeAll()` is blind to it (separate `DatabaseQueue`).
    _ = try await GRDBImportRuleRepository(database: importQueue).create(
      rule(name: "Imported"))

    // The import fires the shared registry's change stream; the store must
    // re-fetch and surface the rule it never observed.
    try await SharedRegistryTestSupport.fireRegistryChange(on: registry)

    await expectEventually("registry tick live-refreshes the imported rule") {
      store.rules.count == 1 && store.rules.first?.name == "Imported"
    }

    store.stopObserving()
    await store.awaitObservationTermination()
  }

  @Test("registry change after stopObserving does not refresh the store")
  func registryChangeAfterStopDoesNotRefresh() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = ImportRuleStore(
      repository: backend.importRules, instrumentChanges: registry)
    try await store.waitForFirstEmission()
    await store.drainPendingEmissions()
    store.stopObserving()
    await store.awaitObservationTermination()

    try await SharedRegistryTestSupport.fireRegistryChange(on: registry)

    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("stale instrument-registry refresh does not clobber a fresher rules snapshot")
  func staleRegistryRefreshIsDropped() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = ImportRuleStore(
      repository: backend.importRules, instrumentChanges: registry)
    _ = try await backend.importRules.create(rule(name: "First", position: 0))
    await expectEventually("first rule visible") {
      store.rules.contains { $0.name == "First" }
    }

    let observedGeneration = store.snapshotGeneration

    _ = try await backend.importRules.create(rule(name: "Second", position: 1))
    await expectEventually("second rule visible") {
      store.rules.contains { $0.name == "Second" }
    }

    // The stale, empty refetch resolves last. It must be dropped, not applied.
    await store.applyInstrumentRegistryRefresh([], observedGeneration: observedGeneration)
    #expect(store.rules.contains { $0.name == "First" })
    #expect(store.rules.contains { $0.name == "Second" })

    store.stopObserving()
  }

  @Test("up-to-date instrument-registry refresh applies")
  func currentRegistryRefreshApplies() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = ImportRuleStore(
      repository: backend.importRules, instrumentChanges: registry)
    let existing = try await backend.importRules.create(rule(name: "Original", position: 0))
    await expectEventually("rule visible") {
      store.rules.contains { $0.name == "Original" }
    }

    let observedGeneration = store.snapshotGeneration
    let renamed = rule(id: existing.id, name: "Renamed", position: existing.position)
    await store.applyInstrumentRegistryRefresh([renamed], observedGeneration: observedGeneration)
    #expect(store.rules.contains { $0.name == "Renamed" })

    store.stopObserving()
  }
}
