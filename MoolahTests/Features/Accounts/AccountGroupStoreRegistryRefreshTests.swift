import Foundation
import GRDB
import Testing

@testable import Moolah

/// Cross-database refresh coverage for the reactive `AccountGroupStore`.
///
/// An in-app profile import writes the `account_group` rows through a
/// GRDB connection that the already-open session's `observeAll()` does
/// not observe (the import path and the live session can hold separate
/// `DatabaseQueue`s over the same file). The per-profile data observation
/// therefore never fires, so the sidebar's group headers stay missing
/// until an app restart re-reads the file — the bug these tests pin.
///
/// `AccountStore` / `EarmarkStore` / `TransactionStore` already dodge this
/// by additionally consuming the shared instrument registry's
/// `observeChanges()` stream and re-running `fetchAll()` on each tick —
/// and an import always fires that stream (it registers every non-fiat
/// denomination before the per-profile write). These tests pin that
/// `AccountGroupStore` consumes the same stream so an open sidebar
/// live-refreshes its groups across the DB boundary.
@Suite("AccountGroupStore registry refresh", .serialized)
@MainActor
struct AccountGroupStoreRegistryRefreshTests {

  /// Registers an arbitrary crypto instrument on the shared registry,
  /// which fires its `observeChanges()` stream — the signal an import
  /// emits via `registerInstruments` before writing the per-profile rows.
  private func fireRegistryChange(
    on registry: GRDBInstrumentRegistryRepository
  ) async throws {
    let crypto = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
      symbol: "WBTC", name: "Wrapped Bitcoin", decimals: 8)
    try await registry.registerCrypto(
      crypto,
      mapping: CryptoProviderMapping(
        instrumentId: crypto.id, coingeckoId: "wrapped-bitcoin",
        cryptocompareSymbol: nil, binanceSymbol: nil))
  }

  @Test("registry tick refreshes groups written via a separate connection")
  func registryTickRefreshesGroupsAcrossConnections() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AccountGroupStoreRegistryRefreshTests-\(UUID().uuidString)")
    // Run the scenario in a helper so the two `DatabaseQueue`s and the store
    // are released (closing their SQLite connections) before the directory
    // is deleted — otherwise unlinking the open `data.sqlite` trips libsqlite3's
    // "vnode unlinked while in use" integrity check.
    try await runCrossConnectionRefresh(in: directory)
    try? FileManager.default.removeItem(at: directory)
  }

  /// Drives the cross-connection refresh and tears down every DB handle
  /// before returning. The "live session" connection the store observes and
  /// the "import" connection the new row is written through are two queues
  /// over one WAL file, so the store's `observeAll()` is blind to the import
  /// write — only the registry backstop can surface it.
  private func runCrossConnectionRefresh(in directory: URL) async throws {
    let url = directory.appendingPathComponent("data.sqlite")
    let sessionQueue = try ProfileDatabase.open(at: url)
    let importQueue = try ProfileDatabase.open(at: url)

    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = AccountGroupStore(
      repository: GRDBAccountGroupRepository(database: sessionQueue),
      instrumentChanges: registry)
    try await store.waitForFirstEmission()
    #expect(store.groups.isEmpty)

    // The import writes the group through its own connection. The session's
    // `observeAll()` is blind to this (separate `DatabaseQueue`), so without
    // the registry backstop the store stays empty until a restart.
    _ = try await GRDBAccountGroupRepository(database: importQueue).create(
      AccountGroup(
        name: "Imported Crypto", bucket: .investments,
        instrument: .defaultTestInstrument))

    // The import fires the shared registry's change stream; the store must
    // re-fetch and surface the group it never observed.
    try await fireRegistryChange(on: registry)

    await expectEventually("registry tick live-refreshes the imported group") {
      store.groups.count == 1 && store.groups.first?.name == "Imported Crypto"
    }

    // Stop observation and await termination so no task retains the store
    // past this scope; the store and both queues then deinit on return,
    // closing the file before the caller deletes it.
    store.stopObserving()
    await store.awaitObservationTermination()
  }

  @Test("registry change after stopObserving does not refresh the store")
  func registryChangeAfterStopDoesNotRefresh() async throws {
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = AccountGroupStore(
      repository: backend.accountGroups, instrumentChanges: registry)
    try await store.waitForFirstEmission()
    await store.drainPendingEmissions()
    store.stopObserving()
    await store.awaitObservationTermination()

    try await fireRegistryChange(on: registry)

    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("stale instrument-registry refresh does not clobber a fresher groups snapshot")
  func staleRegistryRefreshIsDropped() async throws {
    // The registry refresh path captures the generation BEFORE its
    // `fetchAll()`. A fetch that read the database before a concurrent write
    // committed returns a stale row set; without the generation guard,
    // applying it after a fresher authoritative snapshot would clobber
    // `groups` back to the pre-write state. The guard must drop it.
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = AccountGroupStore(
      repository: backend.accountGroups, instrumentChanges: registry)
    let first = try await backend.accountGroups.create(
      AccountGroup(name: "First", bucket: .investments, instrument: .defaultTestInstrument))
    try await store.waitForNextEmission(
      matching: { $0.by(id: first.id) != nil }, description: "first group visible")

    // The registry path would capture the generation here, before its fetch.
    let observedGeneration = store.snapshotGeneration

    // An authoritative `observeAll()` snapshot lands while the (simulated)
    // stale fetch is still in flight, bumping the generation.
    let second = try await backend.accountGroups.create(
      AccountGroup(name: "Second", bucket: .investments, instrument: .defaultTestInstrument))
    try await store.waitForNextEmission(
      matching: { $0.by(id: second.id) != nil }, description: "second group visible")

    // The stale, empty refetch resolves last. It must be dropped, not applied.
    await store.applyInstrumentRegistryRefresh([], observedGeneration: observedGeneration)
    #expect(store.by(id: first.id) != nil)
    #expect(store.by(id: second.id) != nil)

    store.stopObserving()
  }

  @Test("up-to-date instrument-registry refresh applies")
  func currentRegistryRefreshApplies() async throws {
    // Companion to `staleRegistryRefreshIsDropped`: when no authoritative
    // snapshot has landed since the fetch was issued, the refresh applies —
    // this is the cross-connection re-read the path exists for.
    let (backend, _) = try TestBackend.create()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let store = AccountGroupStore(
      repository: backend.accountGroups, instrumentChanges: registry)
    let group = try await backend.accountGroups.create(
      AccountGroup(name: "Original", bucket: .investments, instrument: .defaultTestInstrument))
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id) != nil }, description: "group visible")

    // Capture the current generation and apply a refresh tagged with it —
    // simulating a fetch that observed the latest snapshot. A renamed copy
    // proves the refresh was applied rather than dropped.
    let observedGeneration = store.snapshotGeneration
    var renamed = group
    renamed.name = "Renamed"
    await store.applyInstrumentRegistryRefresh([renamed], observedGeneration: observedGeneration)
    #expect(store.by(id: group.id)?.name == "Renamed")

    store.stopObserving()
  }
}
