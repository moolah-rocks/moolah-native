import CloudKit
import Foundation
import GRDB

extension ProfileSession {
  // MARK: - Registry Wiring

  /// Bundle of the optional instrument-registry pieces: the registry,
  /// crypto token store, search service, CoinGecko catalog, the Binance
  /// token cache, and the token resolution client. Populated for CloudKit
  /// profiles; nil fields indicate a degraded state (e.g. catalog or cache
  /// init failure).
  ///
  /// `catalogRefreshTask` carries the once-per-session CoinGecko
  /// `refreshIfStale()` background task; `cacheRefreshTasks` carries the
  /// once-per-session Binance `refreshIfStale()` task. Both are stored on
  /// `ProfileSession` so they can be cancelled on teardown. `nil` (or an
  /// empty array) when the corresponding construction failed.
  ///
  /// `binanceCache` is exposed so the reconciliation pass can reach the same
  /// warm cache instance the resolver reads.
  struct RegistryWiring {
    let registry: (any InstrumentRegistryRepository)?
    let cryptoTokenStore: CryptoTokenStore?
    let searchService: InstrumentSearchService?
    let coinGeckoCatalog: (any CoinGeckoCatalog)?
    let binanceCache: BinanceTokenCache?
    let tokenResolutionClient: (any TokenResolutionClient)?
    let catalogRefreshTask: Task<Void, Never>?
    let cacheRefreshTasks: [Task<Void, Never>]
  }

  /// The catalog + cache instances and their background refresh tasks, built
  /// once per session and threaded into both the search service and the
  /// resolution client. Extracted so `makeRegistryWiring` stays within the
  /// function-body length limit. Under UI testing the caches are `nil` and the
  /// refresh handles are empty — overrides supply the resolver directly.
  private struct ResolutionWiring {
    let catalog: (any CoinGeckoCatalog)?
    let binanceCache: BinanceTokenCache?
    let resolutionClient: any TokenResolutionClient
    let catalogRefreshTask: Task<Void, Never>?
    let cacheRefreshTasks: [Task<Void, Never>]
  }

  /// Resolves the instrument-registry wiring for a CloudKit profile. Returns
  /// a populated bundle; nil fields indicate a degraded state (e.g. catalog
  /// init failure).
  ///
  /// CloudKit profiles also build a `SQLiteCoinGeckoCatalog` and a
  /// `BinanceTokenCache`, firing each one's `refreshIfStale()` once per
  /// session on a background task so the on-disk snapshots honour the 24 h
  /// max-age + ETag guards without blocking session init. A construction
  /// failure (e.g. a SQLite file can't be opened) is logged and the
  /// corresponding handle is left `nil` — search/resolution degrade to the
  /// live-download / registry / Yahoo paths only.
  ///
  /// Under `--ui-testing` the active `UITestSeed` may register fake
  /// catalog/resolver implementations via
  /// `UITestSeedCryptoOverrides.overrides(for:)` — those replace the live
  /// SQLite snapshot and `CompositeTokenResolutionClient` so the picker
  /// flow runs deterministically without disk or network access.
  @MainActor
  static func makeRegistryWiring(
    backend: BackendProvider,
    cryptoPriceService: CryptoPriceService,
    yahooPriceFetcher: any YahooFinancePriceFetcher,
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices,
    sharedRegistryStore: SharedRegistryStore? = nil
  ) -> RegistryWiring {
    guard let cloudBackend = backend as? CloudKitBackend else {
      fatalError("makeBackend only constructs CloudKitBackend")
    }

    let wiring = makeResolutionWiring(
      coinGeckoApiKeyProvider: coinGeckoApiKeyProvider, networking: networking)
    // Pass the shared registry store from the coordinator when
    // wired so cross-session mutations are observed transparently
    // through the proxy. Falls back to local storage when no
    // coordinator is wired (preview / legacy tests).
    //
    // `CryptoTokenStore.hasAlchemyApiKey` checks
    // `UITestEnvironment.alchemyKeyPresent` in the launch environment
    // before reading the keychain, so seeds that need `hasCredential ==
    // true` (e.g. `.walletHeaderSyncError`) can signal that via env var
    // without writing to the system keychain — which can trigger
    // interactive authorization dialogs in headless CI environments.
    // Custom RPC endpoints normally persist to the synchronizable Keychain.
    // In UI tests that write fails on a headless CI runner and, because an
    // add reverts on save failure, the row would vanish — so under the same
    // env flag that stubs the endpoint probe we use an in-memory store.
    let rpcEndpointsStore: any CryptoRPCEndpointsStoring =
      ProcessInfo.processInfo.environment[UITestEnvironment.rpcProbeStubbedReachable] == "1"
      ? InMemoryCryptoRPCEndpointsStore()
      : CryptoRPCEndpointsStore()
    let store = CryptoTokenStore(
      registry: cloudBackend.instrumentRegistryRepository,
      cryptoPriceService: cryptoPriceService,
      conversionService: cloudBackend.conversionService,
      rpcEndpointsStore: rpcEndpointsStore,
      sharedStore: sharedRegistryStore)
    let searchService = InstrumentSearchService(
      registry: cloudBackend.instrumentRegistryRepository,
      catalog: wiring.catalog,
      resolutionClient: wiring.resolutionClient,
      stockSearchClient: YahooFinanceStockSearchClient(
        http: networking.client(forHost: "query1.finance.yahoo.com"))
    )
    return RegistryWiring(
      registry: cloudBackend.instrumentRegistryRepository,
      cryptoTokenStore: store,
      searchService: searchService,
      coinGeckoCatalog: wiring.catalog,
      binanceCache: wiring.binanceCache,
      tokenResolutionClient: wiring.resolutionClient,
      catalogRefreshTask: wiring.catalogRefreshTask,
      cacheRefreshTasks: wiring.cacheRefreshTasks
    )
  }

  /// Builds the catalog, the Binance cache, and the resolution client (with
  /// its background refresh task). Under UI testing it returns the seed's
  /// override catalog + resolver and no live caches.
  @MainActor
  private static func makeResolutionWiring(
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices
  ) -> ResolutionWiring {
    if let overrides = uiTestingCryptoOverrides() {
      return ResolutionWiring(
        catalog: overrides.catalog,
        binanceCache: nil,
        resolutionClient: overrides.resolutionClient,
        catalogRefreshTask: nil,
        cacheRefreshTasks: [])
    }
    let made = makeCoinGeckoCatalog(
      coinGeckoApiKeyProvider: coinGeckoApiKeyProvider, networking: networking)
    // Build the Binance cache alongside the CoinGecko catalog, firing its
    // own once-per-session background `refreshIfStale()`. The resolver
    // consults it in place of an ad-hoc full exchange-info download; a nil
    // cache (open failure) degrades the resolver to its live-download path.
    let madeBinance = makeBinanceCache(networking: networking)
    let cacheRefreshTasks = [madeBinance.refreshTask].compactMap { $0 }
    // Resolves the key per request: an empty key targets the free public
    // CoinGecko endpoint, a configured key the Pro host. Coalesce a missing
    // keychain entry to `""` so the resolver always runs the free-tier path
    // (it treats `nil` as opt-out). See `makeCryptoPriceService`.
    let resolutionClient = CompositeTokenResolutionClient(
      networking: networking,
      coinGeckoApiKeyProvider: { coinGeckoApiKeyProvider() ?? "" },
      binanceLookup: madeBinance.cache)
    return ResolutionWiring(
      catalog: made.catalog,
      binanceCache: madeBinance.cache,
      resolutionClient: resolutionClient,
      catalogRefreshTask: made.refreshTask,
      cacheRefreshTasks: cacheRefreshTasks)
  }

  /// The active UI-test seed, or `nil` for a production launch. Reads the same
  /// argument + env var (`--ui-testing` / `UI_TESTING_SEED`) consumed by
  /// `MoolahApp+Setup.uiTestingSeed(from:)`. Shared by every UI-testing
  /// override helper so the gating logic lives in one place.
  static func currentUITestSeed() -> UITestSeed? {
    guard CommandLine.arguments.contains("--ui-testing") else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["UI_TESTING_SEED"] else { return nil }
    return UITestSeed(rawValue: raw)
  }

  /// Returns the catalog/resolver overrides for the active UI test seed,
  /// or `nil` for production launches. Reads the same arguments and
  /// environment variable that `MoolahApp+Setup.uiTestingSeed(from:)`
  /// consumes during app init — keeping the gating consistent between the
  /// two call sites.
  @MainActor
  private static func uiTestingCryptoOverrides()
    -> (catalog: any CoinGeckoCatalog, resolutionClient: any TokenResolutionClient)?
  {
    guard let seed = currentUITestSeed() else { return nil }
    return UITestSeedCryptoOverrides.overrides(for: seed)
  }

  /// `internal` (not `private`) because the caller, `finishInit`, lives in
  /// `ProfileSession.swift` — Swift's `private` does not cross file boundaries
  /// even within the same type. Mirrors `uiTestingCryptoOverrides()` except for
  /// this access level. `@MainActor` because `UITestSeedInsightOverrides` is a
  /// `@MainActor` type, so calling its static methods requires that isolation.
  @MainActor
  static func uiTestingInsightFixtures() -> InsightFixtures? {
    guard let seed = currentUITestSeed() else { return nil }
    return UITestSeedInsightOverrides.fixtures(for: seed)
  }

  #if DEBUG
    /// Returns a `FixedModelAvailability` override for the active UI-test seed,
    /// or `nil` for production launches (or seeds that don't need a fixed
    /// availability). `@MainActor` because `UITestSeedInsightOverrides` is a
    /// `@MainActor` type.
    @MainActor
    static func uiTestingInsightAvailability() -> FixedModelAvailability? {
      guard let seed = currentUITestSeed() else { return nil }
      return UITestSeedInsightOverrides.availability(for: seed)
    }

    /// Returns a `ScriptedNarrator` override for the active UI-test seed,
    /// or `nil` for production launches (or seeds that don't need a scripted
    /// narrator). `@MainActor` because `UITestSeedInsightOverrides` is a
    /// `@MainActor` type.
    @MainActor
    static func uiTestingInsightNarrator() -> ScriptedNarrator? {
      guard let seed = currentUITestSeed() else { return nil }
      return UITestSeedInsightOverrides.narrator(for: seed)
    }

  #endif
}
