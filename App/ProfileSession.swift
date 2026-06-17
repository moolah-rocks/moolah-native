import CloudKit
import Foundation
import GRDB
import OSLog

/// Holds the backend and all stores for a single profile.
/// Each profile gets its own isolated URLSession, cookie storage, and keychain entry.
@Observable
@MainActor
final class ProfileSession: Identifiable {
  var profile: Profile
  /// Per-profile GRDB connection. Owns the lifecycle of `data.sqlite`
  /// (or an in-memory queue under previews / tests). Released when the
  /// session deinits; on profile delete the parent `profiles/<id>/`
  /// directory is removed by `ProfileContainerManager.deleteStore`.
  ///
  /// Module-internal so `ProfileSession+DatabaseMaintenance.swift` can
  /// invoke `database.write` for `PRAGMA optimize`. External consumers
  /// must still go through repositories and the rate services rather than
  /// poking the queue directly.
  let database: DatabaseQueue
  let backend: BackendProvider
  let authStore: AuthStore
  let accountStore: AccountStore
  let transactionStore: TransactionStore
  let categoryStore: CategoryStore
  let earmarkStore: EarmarkStore
  /// `private(set) var` (rather than `let`) so it can be assigned from
  /// `finishInit()` rather than the main `init` body. Functionally
  /// `let` from the consumer's perspective — no caller mutates it.
  /// Pattern mirrors `cryptoSyncStore` / `cryptoTokenDiscovery`.
  /// The optional is *always* set by the end of init (the
  /// `finishInit()` tail runs synchronously inside `init`), so
  /// consumers can force-unwrap if needed; the type stays optional to
  /// satisfy SwiftLint's `implicitly_unwrapped_optional` rule.
  private(set) var accountGroupStore: AccountGroupStore?
  /// Sidebar expand / collapse state for `AccountGroup` rows.
  /// Local-only (per-device). Same `finishInit`-assigned pattern as
  /// `accountGroupStore`; functionally `let` from the consumer.
  private(set) var groupUIStateStore: GroupUIStateStore?
  /// Same `finishInit`-assigned pattern as `accountGroupStore`: `InsightStore`
  /// depends on `accountGroupStore` (also wired in `finishInit`), so it is
  /// constructed there rather than in `makeDomainStores`. Functionally `let`
  /// from the consumer's perspective.
  private(set) var insightStore: InsightStore?
  let analysisStore: AnalysisStore
  let investmentStore: InvestmentStore
  let reportingStore: ReportingStore
  let exchangeRateService: ExchangeRateService
  let stockPriceService: StockPriceService
  let cryptoPriceService: CryptoPriceService
  // Assigned once in `finishInit` (not the main `init` body) to keep `init`
  // within the `function_body_length` budget — same pattern as
  // `accountGroupStore` / `cryptoSyncStore` below. `private(set) var` rather
  // than `let` because Swift can't prove a `let` is set in a method `init`
  // calls.
  private(set) var instrumentRegistry: (any InstrumentRegistryRepository)?
  private(set) var cryptoTokenStore: CryptoTokenStore?
  private(set) var instrumentSearchService: InstrumentSearchService?
  private(set) var coinGeckoCatalog: (any CoinGeckoCatalog)?
  /// Self-refreshing CryptoCompare / Binance token caches the resolution
  /// client reads from. Exposed so PR2's preset reconciliation can reach the
  /// same warm cache instances. `nil` when cache construction failed (or under
  /// UI testing, where overrides supply the resolver directly).
  private(set) var cryptoCompareCache: CryptoCompareTokenCache?
  private(set) var binanceCache: BinanceTokenCache?
  private(set) var tokenResolutionClient: (any TokenResolutionClient)?
  /// Orchestrator for crypto-wallet auto-import. `nil` when the profile
  /// has no `instrumentRegistry` (preview / degraded launches). Set
  /// once in `finishInit` after `init` returns; effectively `let` from
  /// the consumer's perspective. `private(set)` so callers cannot
  /// reassign.
  private(set) var cryptoSyncStore: SyncedAccountStore?

  /// Token resolver shared with the inbox UI. Nil with `cryptoSyncStore`.
  /// Same lifecycle pattern as `cryptoSyncStore`.
  private(set) var cryptoTokenDiscovery: CryptoTokenDiscoveryService?
  let importStore: ImportStore
  let importRuleStore: ImportRuleStore
  let importPreferences: ImportPreferences
  private let folderScanner: FolderScanService
  private let folderWatcher: FolderWatchService

  /// Non-nil while a profile export is in progress. Set by the File menu's
  /// export command; read by `SessionRootView` to present a progress sheet
  /// (see issue #359). `nil` when idle so the sheet dismisses automatically.
  var activeExport: ActiveExport?

  /// Stable profile identity captured at init time so the nonisolated
  /// `id` accessor (used by `Identifiable` conformance / SwiftUI diffing)
  /// does not have to read the main-actor-isolated `profile` property.
  /// `updateProfile(_:)` preconditions on `updated.id == profile.id`,
  /// so this stays in lockstep with `profile.id` for the session's
  /// lifetime.
  nonisolated private let profileID: UUID

  nonisolated var id: UUID { profileID }

  /// Module-internal so `ProfileSession+SyncCleanup.swift` and
  /// `ProfileSession+DatabaseMaintenance.swift` can log without needing
  /// their own Logger instances.
  let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSession")
  /// Background task handle for the once-per-session CoinGecko
  /// `refreshIfStale()` kick-off. Tracked so it can be cancelled in
  /// `cleanupSync(coordinator:)` if the session is torn down before the
  /// refresh completes. Module-internal for the sync-cleanup extension.
  var catalogRefreshTask: Task<Void, Never>?
  /// Background task handles for the once-per-session CryptoCompare / Binance
  /// `refreshIfStale()` kick-offs. Tracked as siblings to `catalogRefreshTask`
  /// so they can be cancelled in `cleanupSync(coordinator:)` if the session is
  /// torn down before the refresh completes. Empty when cache construction
  /// failed (or under UI testing). Module-internal for the sync-cleanup
  /// extension.
  var cacheRefreshTasks: [Task<Void, Never>] = []
  /// Background task handle for the most recent `PRAGMA optimize` kick-off.
  /// Tracked so we can cancel any pending optimize on session teardown
  /// (per `guides/CONCURRENCY_GUIDE.md` §8 — fire-and-forget tasks must
  /// be tracked). Replaced (with cancellation of the prior handle) on
  /// each call to `schedulePragmaOptimize()`. Module-internal so
  /// `ProfileSession+DatabaseMaintenance.swift` can manage the handle.
  var pragmaOptimizeTask: Task<Void, Never>?
  /// Long-lived task that fires `runPragmaOptimize` at most once per
  /// configured interval while the session is active. Cancelled in
  /// `cleanupSync(coordinator:)` so it cannot outlive the session.
  /// Replaced (with cancellation of the prior handle) on each call to
  /// `startPeriodicPragmaOptimize(interval:)` so a new cadence supersedes
  /// the previous one rather than running alongside it. Module-internal
  /// for the same reason as `pragmaOptimizeTask`.
  var periodicPragmaOptimizeTask: Task<Void, Never>?
  /// Number of times `runPragmaOptimize` has completed for this session.
  /// Incremented after each invocation regardless of success — failures
  /// are still attempts, and the counter is consumed by tests that pin
  /// the hourly-while-active cadence (see issue #576). Module-internal
  /// because `runPragmaOptimize` lives in
  /// `ProfileSession+DatabaseMaintenance.swift`; mutated only there.
  var pragmaOptimizeRunCount: Int = 0
  /// Tasks spawned by cross-store side effects (e.g.
  /// `seedBuiltInCryptoPresets`, the `cryptoTokenStore` ->
  /// `investmentStore.revaluateLoadedPositions` callback). Kept
  /// reachable so `cleanupSync` can cancel in-flight work (per
  /// `guides/CONCURRENCY_GUIDE.md` §8). Module-internal so
  /// `ProfileSession+SyncCleanup.swift` can drain the list on teardown.
  var crossStoreUpdateTasks: [Task<Void, Never>] = []

  /// Tracks the in-flight (or completed) `setUp()` call so callers can
  /// `await session.setUp()` without re-running it. Set by `setUp()` on
  /// its first invocation; subsequent calls return the same task. `nil`
  /// until the first call. Tracked here (rather than in
  /// `SessionManager`) so any caller with the session reference can
  /// await bootstrap completion. Module-internal so
  /// `ProfileSession+SyncCleanup.swift` can cancel a pending bootstrap
  /// during teardown.
  var setUpTask: Task<Void, any Error>?

  /// Synchronous initialiser — opens the per-profile GRDB queue and
  /// builds every store / service the session exposes. Callers must
  /// invoke `try await session.setUp()` before any code path that
  /// expects post-bootstrap state (e.g. `ValuationModeMigration`
  /// effects) to be visible — `SessionManager.session(for:)` schedules
  /// this automatically when it creates the session.
  init(
    profile: Profile,
    containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil,
    database: DatabaseQueue? = nil,
    networking: NetworkingServices? = nil
  ) throws {
    self.profile = profile
    self.profileID = profile.id

    let resolvedDatabase = try Self.resolveDatabase(
      override: database, profile: profile, containerManager: containerManager)
    self.database = resolvedDatabase

    // Prefer the app-level shared `NetworkingServices` via SyncCoordinator,
    // fall back to the directly-injected one, then to a fresh instance for
    // preview / test fixtures that didn't pass shared services through.
    let resolvedNetworking = syncCoordinator?.sharedNetworking ?? networking ?? NetworkingServices()

    // Prefer the app-level shared `MarketDataServices` (pointed at
    // the profile-index DB) when the coordinator was constructed
    // with one. All sessions then share price-cache writes / reads,
    // so a CoinGecko fetch for `bitcoin` in profile A populates the
    // cache that profile B reads next. Falls back to per-profile
    // construction for legacy callers (preview / tests) that didn't
    // pass shared services through `SyncCoordinator.init`.
    let services =
      syncCoordinator?.sharedMarketData
      ?? Self.makeMarketDataServices(database: resolvedDatabase, networking: resolvedNetworking)
    self.exchangeRateService = services.exchangeRate
    self.stockPriceService = services.stockPrice
    self.cryptoPriceService = services.cryptoPrice

    let backend = Self.makeBackend(
      profile: profile,
      syncCoordinator: syncCoordinator,
      services: services,
      database: resolvedDatabase
    )
    self.backend = backend

    // Built here (it needs the init-locals `services` / `resolvedNetworking` /
    // `syncCoordinator`) but assigned in `finishInit` — see its declarations.
    let registryWiring = Self.makeRegistryWiring(
      backend: backend,
      cryptoPriceService: services.cryptoPrice,
      yahooPriceFetcher: services.yahooPriceFetcher,
      coinGeckoApiKeyProvider: services.coinGeckoApiKeyProvider,
      networking: resolvedNetworking,
      sharedRegistryStore: syncCoordinator?.sharedRegistryStore
    )
    let stores = Self.makeDomainStores(profile: profile, backend: backend)
    self.authStore = stores.auth
    self.accountStore = stores.account
    self.categoryStore = stores.category
    self.earmarkStore = stores.earmark
    self.transactionStore = stores.transaction
    self.analysisStore = stores.analysis
    self.investmentStore = stores.investment
    self.reportingStore = stores.reporting
    // CSV import: ImportStore owns the pipeline orchestration; the
    // staging store lives per-profile on disk so pending/failed files
    // follow the profile across app restarts.
    let importPipeline = Self.makeImportPipeline(
      backend: backend, profileId: profile.id, logger: logger)
    self.importStore = importPipeline.importStore
    self.importRuleStore = importPipeline.importRuleStore
    self.importPreferences = importPipeline.preferences
    self.folderScanner = importPipeline.scanner
    self.folderWatcher = importPipeline.watcher

    finishInit(registryWiring: registryWiring)
  }

  /// Tail of the initialiser. Wires
  /// the crypto-wallet sync stores and starts the hourly
  /// `PRAGMA optimize` tick (issue #576). Reads everything it needs
  /// from `self` (every stored property is fully initialised by the
  /// time `init` calls this).
  ///
  /// Cross-store propagation is handled reactively: every store
  /// subscribes to its repository's GRDB `ValueObservation` stream in
  /// `init`, so remote-sync writes (and local writes) reach views
  /// without an explicit reload step. The session needs no reference
  /// to `SyncCoordinator` here — apply drives GRDB writes and the
  /// observation streams take it from there.
  private func finishInit(registryWiring: RegistryWiring) {
    // MUST run before `makeCryptoSyncWiring` / `seedBuiltInCryptoPresets`
    // below, which read `instrumentRegistry`.
    self.instrumentRegistry = registryWiring.registry
    self.cryptoTokenStore = registryWiring.cryptoTokenStore
    self.instrumentSearchService = registryWiring.searchService
    self.coinGeckoCatalog = registryWiring.coinGeckoCatalog
    self.cryptoCompareCache = registryWiring.cryptoCompareCache
    self.binanceCache = registryWiring.binanceCache
    self.tokenResolutionClient = registryWiring.tokenResolutionClient
    self.catalogRefreshTask = registryWiring.catalogRefreshTask
    self.cacheRefreshTasks = registryWiring.cacheRefreshTasks
    // AccountGroupStore is constructed here (rather than the main
    // `init` body) so the init stays within the
    // `function_body_length` budget — same pattern as `cryptoSyncStore`
    // / `cryptoTokenDiscovery` below.
    self.accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
    self.groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
    // InsightStore is wired here (not in `makeDomainStores`) because it reads
    // `accountGroupStore`, which is itself constructed in `finishInit` — by
    // this point every `self.*Store` sibling it bundles already exists.
    let insightSources = InsightStoreSources(
      analysis: analysisStore,
      earmark: earmarkStore,
      reporting: reportingStore,
      account: accountStore,
      accountGroup: accountGroupStore,
      category: categoryStore)
    // UI-test seeds may inject a fixed availability and a scripted narrator so
    // the narration path is exercised deterministically on CI hardware (no real
    // model required). Production launches receive nil from both helpers and
    // fall through to the live implementations. The `#if DEBUG` guard is safe
    // here because UI-test host builds always compile as Debug.
    #if DEBUG
      let uiTestAvailability = Self.uiTestingInsightAvailability()
      let uiTestNarrator = Self.uiTestingInsightNarrator()
      let insightAvailability: any ModelAvailabilityProviding =
        uiTestAvailability ?? SystemLanguageModelAvailability()
      let insightNarrator: any InsightNarrating =
        uiTestNarrator ?? Self.makeInsightNarrator()
    #else
      let insightAvailability: any ModelAvailabilityProviding = SystemLanguageModelAvailability()
      let insightNarrator: any InsightNarrating = Self.makeInsightNarrator()
    #endif
    let builtInsightStore = InsightStore(
      sources: insightSources,
      backend: backend,
      profile: profile,
      instrumentChanges: backend.instrumentChangeObserver,
      availability: insightAvailability,
      narrator: insightNarrator,
      fixtureInsights: Self.uiTestingInsightFixtures())
    self.insightStore = builtInsightStore
    let cryptoWiring = Self.makeCryptoSyncWiring(
      backend: backend,
      registry: instrumentRegistry,
      cryptoPriceService: cryptoPriceService,
      profileInstrument: profile.instrument)
    self.cryptoSyncStore = cryptoWiring?.store
    self.cryptoTokenDiscovery = cryptoWiring?.discovery
    seedBuiltInCryptoPresets(registry: instrumentRegistry)
    wireCrossStoreSideEffects()
    startPeriodicPragmaOptimize()
  }

  /// Fires `registerBuiltInPresetsIfMissing` on the profile's registry
  /// so chain native gas tokens (ETH on Ethereum / OP / Base; MATIC on
  /// Polygon) and well-known ERC-20s carry a real provider mapping
  /// before any conversion path consults the registry. Without this,
  /// transaction detail / running-balance render fails for crypto legs
  /// the very first time a profile reads them — issue #791. Tracked in
  /// `crossStoreUpdateTasks` so `cleanupSync` cancels in-flight seeds
  /// when the session tears down.
  private func seedBuiltInCryptoPresets(
    registry: (any InstrumentRegistryRepository)?
  ) {
    guard let registry else { return }
    let task = Task {
      await registry.registerBuiltInPresetsIfMissing()
    }
    crossStoreUpdateTasks.append(task)
  }

  /// Wires the crypto-token-store -> investment-store hook: when a
  /// registration's `pricingStatus` flips (e.g. user marks a token as
  /// `.spam` from preferences), the loaded investment account
  /// re-valuates so the spam position drops out of `valuedPositions`
  /// without the user having to navigate away and back. Issue #790.
  ///
  /// The investment-store -> account-store fan-out is reactive:
  /// AccountStore subscribes to
  /// `investmentRepository.observeAllValues()` and refreshes its cache
  /// directly, so a write to `investment_value` reaches the sidebar
  /// without a callback. The spawned crypto-token Task is tracked in
  /// `crossStoreUpdateTasks` so `cleanupSync` can cancel in-flight
  /// revaluations on session teardown.
  private func wireCrossStoreSideEffects() {
    let investmentStore = self.investmentStore
    self.cryptoTokenStore?.onRegistrationsChanged = { [weak self] in
      let task = Task { @MainActor in
        await investmentStore.revaluateLoadedPositions()
      }
      self?.crossStoreUpdateTasks.append(task)
    }
  }

  // `cleanupSync(coordinator:)` and `updateProfile(_:)` live in
  // `ProfileSession+SyncCleanup.swift`.

  // MARK: - Folder watch

  /// Kick off the folder watch: catches up on any files added while the app
  /// was closed and (on macOS) opens an FSEvents stream for live updates.
  /// Safe to call repeatedly; stop() must be paired with start() for state
  /// hygiene.
  func startFolderWatch() async {
    await folderWatcher.start()
  }

  /// Stop the folder watch and release the security-scoped resource.
  func stopFolderWatch() {
    folderWatcher.stop()
  }

  /// Catch-up scan — used at launch / foreground on iOS where the live
  /// watch isn't available.
  func scanWatchedFolder() async {
    await folderScanner.scanForNewFiles()
  }

  /// Runs the bootstrap migrations off `@MainActor` and reloads the
  /// affected stores. Idempotent: subsequent calls return the same
  /// task so callers can `await session.setUp()` from multiple sites
  /// (UI test seed setup, `SessionManager.session(for:)`, etc.) without
  /// re-running anything.
  ///
  /// `ValuationModeMigration` is non-fatal: errors are logged but do
  /// not propagate, because read sites auto-detect and the next launch
  /// will retry.
  func setUp() async throws {
    if let existing = setUpTask {
      return try await existing.value
    }
    let task = Task<Void, any Error> {
      await self.runValuationModeMigration()
    }
    setUpTask = task
    try await task.value
  }

  // `runValuationModeMigration` lives in
  // `ProfileSession+ValuationMigration.swift`.
}
