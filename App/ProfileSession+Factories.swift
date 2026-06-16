// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

import CloudKit
import Foundation
import GRDB

extension ProfileSession {
  // MARK: - Market Data Services

  /// Bundle of the external market-data services a profile session depends
  /// on: fiat exchange rates, stock prices, and crypto prices. Returned
  /// from `makeMarketDataServices` so `init` can assign each field in one
  /// step.
  struct MarketDataServices: Sendable {
    let exchangeRate: ExchangeRateService
    let stockPrice: StockPriceService
    let cryptoPrice: CryptoPriceService
    let yahooPriceFetcher: any YahooFinancePriceFetcher
    let coinGeckoApiKeyProvider: @Sendable () -> String?
  }

  /// Builds the fiat/stock/crypto market-data services used throughout the
  /// profile session. Standalone helper so `ProfileSession.init` can build
  /// and assign the trio in one step. Each rate service persists to the
  /// supplied per-profile `database`.
  static func makeMarketDataServices(
    database: any DatabaseWriter,
    networking: NetworkingServices
  ) -> MarketDataServices {
    let yahooClient = YahooFinanceClient(
      http: networking.client(forHost: "query2.finance.yahoo.com"))
    // Closure (not a resolved value): a CoinGecko Pro key entered in Settings
    // after this wiring is built takes effect on the next price fetch / token
    // resolution / catalog refresh without rebuilding the session — every
    // consumer reads the key per request through this provider.
    let cgKeyProvider: @Sendable () -> String? = { ProfileSession.resolveCoinGeckoApiKey() }
    // Read-only handle to the shared CoinGecko catalog so the discovery token
    // resolver can price a known token offline (see `makeLookupCatalog`).
    let lookupCatalog = Self.makeLookupCatalog(
      coinGeckoApiKeyProvider: cgKeyProvider, networking: networking)
    return MarketDataServices(
      exchangeRate: ExchangeRateService(
        client: FrankfurterClient(
          http: networking.client(forHost: "api.frankfurter.app")),
        database: database),
      stockPrice: StockPriceService(client: yahooClient, database: database),
      cryptoPrice: Self.makeCryptoPriceService(
        coinGeckoApiKeyProvider: cgKeyProvider, database: database, networking: networking,
        localResolver: lookupCatalog),
      yahooPriceFetcher: yahooClient,
      coinGeckoApiKeyProvider: cgKeyProvider
    )
  }

  /// Builds the crypto-price service with its configured clients
  /// (CoinGecko first — Pro tier when a key is set, otherwise the free
  /// public endpoint — plus CryptoCompare and Binance as fallbacks) and
  /// the token resolver. The price-service falls through to the next
  /// client on any error, so an anonymous CoinGecko 429 still resolves
  /// via CryptoCompare/Binance.
  static func makeCryptoPriceService(
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    database: any DatabaseWriter,
    networking: NetworkingServices,
    localResolver: (any LocalContractResolver)? = nil
  ) -> CryptoPriceService {
    // `CoinGeckoClient` resolves the key per request: an empty key targets
    // the free public host; a configured key targets the Pro host with
    // `x_cg_pro_api_key`. Always included so users without a Pro key still
    // get coverage for tokens like USDC that CryptoCompare omits from its
    // contract index.
    let cryptoCompareClient = CryptoCompareClient(
      http: networking.client(forHost: "min-api.cryptocompare.com"),
      apiKeyProvider: { ProfileSession.resolveCryptoCompareApiKey() })
    let coinGeckoClient = CoinGeckoClient(
      apiKeyProvider: coinGeckoApiKeyProvider, networking: networking)
    let stablecoinClient = StablecoinPriceClient()
    // Binance prices are quoted in USDT; converting them to USD needs a
    // USDT/USD rate. Resolve it through the same provider precedence the main
    // chain uses, ending in the stablecoin peg — so a CryptoCompare outage
    // falls to CoinGecko's real USDT price before assuming parity, and the $1
    // last resort comes from the canonical peg rather than a literal here.
    let usdtRateClients: [CryptoPriceClient] = [
      cryptoCompareClient, coinGeckoClient, stablecoinClient,
    ]
    let binanceClient = BinanceClient(
      http: networking.client(forHost: "api.binance.com"),
      usdtRateLookup: { date in
        let usdtMapping = CryptoProviderMapping(
          instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
          coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
        )
        return await CryptoRateLookup.firstAvailableRate(
          for: usdtMapping, on: date, using: usdtRateClients, default: Decimal(1))
      })
    let priceClients: [CryptoPriceClient] = [
      coinGeckoClient,
      cryptoCompareClient,
      binanceClient,
      // Last-resort $1 fallback for canonical USDC/USDT only (peg).
      stablecoinClient,
    ]

    return CryptoPriceService(
      clients: priceClients,
      database: database,
      resolutionClient: CompositeTokenResolutionClient(
        networking: networking,
        // Coalesce a missing keychain entry to `""` so the resolver always
        // runs the free-tier CoinGecko path (it treats `nil` as opt-out).
        coinGeckoApiKeyProvider: { coinGeckoApiKeyProvider() ?? "" },
        localResolver: localResolver)
    )
  }

  // MARK: - Backend

  /// Builds the CloudKit `BackendProvider` for the profile.
  static func makeBackend(
    profile: Profile,
    syncCoordinator: SyncCoordinator? = nil,
    services: MarketDataServices,
    database: any DatabaseWriter
  ) -> BackendProvider {
    makeCloudKitBackend(
      profile: profile,
      syncCoordinator: syncCoordinator,
      marketData: CloudKitMarketDataServices(
        exchangeRates: services.exchangeRate,
        stockPrices: services.stockPrice,
        cryptoPrices: services.cryptoPrice),
      database: database)
  }

  // MARK: - Registry Wiring

  /// Bundle of the optional instrument-registry pieces: the registry,
  /// crypto token store, search service, CoinGecko catalog, and token
  /// resolution client. Populated for CloudKit profiles; nil fields indicate
  /// a degraded state (e.g. catalog init failure).
  ///
  /// `catalogRefreshTask` carries the once-per-session
  /// `refreshIfStale()` background task so `ProfileSession` can store and
  /// cancel it on teardown. `nil` when catalog construction failed.
  struct RegistryWiring {
    let registry: (any InstrumentRegistryRepository)?
    let cryptoTokenStore: CryptoTokenStore?
    let searchService: InstrumentSearchService?
    let coinGeckoCatalog: (any CoinGeckoCatalog)?
    let tokenResolutionClient: (any TokenResolutionClient)?
    let catalogRefreshTask: Task<Void, Never>?
  }

  /// Resolves the instrument-registry wiring for a CloudKit profile. Returns
  /// a populated bundle; nil fields indicate a degraded state (e.g. catalog
  /// init failure).
  ///
  /// CloudKit profiles also build a `SQLiteCoinGeckoCatalog` and fire its
  /// `refreshIfStale()` once per session on a background task so the on-disk
  /// snapshot honours the 24 h max-age + ETag guards without blocking
  /// session init. A catalog construction failure (e.g. the SQLite file
  /// can't be opened) is logged and the catalog is left `nil` — search
  /// degrades to the registry/Yahoo paths only.
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

    let catalog: (any CoinGeckoCatalog)?
    let refreshTask: Task<Void, Never>?
    let resolutionClient: any TokenResolutionClient
    if let overrides = uiTestingCryptoOverrides() {
      catalog = overrides.catalog
      refreshTask = nil
      resolutionClient = overrides.resolutionClient
    } else {
      let made = makeCoinGeckoCatalog(
        coinGeckoApiKeyProvider: coinGeckoApiKeyProvider, networking: networking)
      catalog = made.catalog
      refreshTask = made.refreshTask
      // Resolves the key per request: an empty key targets the free public
      // CoinGecko endpoint, a configured key the Pro host. Coalesce a missing
      // keychain entry to `""` so the resolver always runs the free-tier path
      // (it treats `nil` as opt-out). See `makeCryptoPriceService`.
      resolutionClient = CompositeTokenResolutionClient(
        networking: networking,
        coinGeckoApiKeyProvider: { coinGeckoApiKeyProvider() ?? "" })
    }
    // Pass the shared registry store from the coordinator when
    // wired so cross-session mutations are observed transparently
    // through the proxy. Falls back to local storage when no
    // coordinator is wired (preview / legacy tests).
    let store = CryptoTokenStore(
      registry: cloudBackend.instrumentRegistryRepository,
      cryptoPriceService: cryptoPriceService,
      conversionService: cloudBackend.conversionService,
      sharedStore: sharedRegistryStore)
    let searchService = InstrumentSearchService(
      registry: cloudBackend.instrumentRegistryRepository,
      catalog: catalog,
      resolutionClient: resolutionClient,
      stockSearchClient: YahooFinanceStockSearchClient(
        http: networking.client(forHost: "query1.finance.yahoo.com"))
    )
    return RegistryWiring(
      registry: cloudBackend.instrumentRegistryRepository,
      cryptoTokenStore: store,
      searchService: searchService,
      coinGeckoCatalog: catalog,
      tokenResolutionClient: resolutionClient,
      catalogRefreshTask: refreshTask
    )
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

  // MARK: - Domain Stores

  /// Bundle of the per-profile domain stores. Returned from
  /// `makeDomainStores` so `ProfileSession.init` can assign each stored
  /// property in one step without inlining every constructor call.
  struct DomainStores {
    let auth: AuthStore
    let account: AccountStore
    let category: CategoryStore
    let earmark: EarmarkStore
    let transaction: TransactionStore
    let analysis: AnalysisStore
    let investment: InvestmentStore
    let reporting: ReportingStore
  }

  /// Builds all of the domain stores for a profile against a shared
  /// `BackendProvider`. Accounts and earmarks are constructed before
  /// transactions because the transaction store depends on them.
  static func makeDomainStores(
    profile: Profile,
    backend: BackendProvider
  ) -> DomainStores {
    // Per-profile list observations don't track an `instrument` table;
    // instrument identity is resolved once per fetch via the shared
    // registry. Thread the registry's change stream into the affected
    // stores so a shared-registry metadata edit live-refreshes an open
    // list across the DB boundary. Derived from the backend (not a
    // parameter); nil for backends without a shared registry. Accessed
    // via the `BackendProvider` seam — no downcast to a concrete backend
    // type.
    let instrumentChanges = backend.instrumentChangeObserver
    let auth = AuthStore(backend: backend)
    let account = AccountStore(
      repository: backend.accounts, conversionService: backend.conversionService,
      targetInstrument: profile.instrument, investmentRepository: backend.investments,
      instrumentChanges: instrumentChanges)
    let category = CategoryStore(repository: backend.categories)
    let earmark = EarmarkStore(
      repository: backend.earmarks, conversionService: backend.conversionService,
      targetInstrument: profile.instrument,
      instrumentChanges: instrumentChanges)
    let transaction = TransactionStore(
      repository: backend.transactions,
      conversionService: backend.conversionService,
      targetInstrument: profile.instrument,
      instrumentChanges: instrumentChanges,
      transferSuggestions: backend.transferSuggestions
    )
    let analysis = AnalysisStore(
      repository: backend.analysis, conversionService: backend.conversionService)
    let investment = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService,
      instrumentChanges: instrumentChanges,
      instrumentRegistry: backend.instrumentRegistry
    )
    let reporting = ReportingStore(
      transactionRepository: backend.transactions,
      analysisRepository: backend.analysis,
      conversionService: backend.conversionService,
      profileCurrency: profile.instrument
    )
    return DomainStores(
      auth: auth, account: account, category: category, earmark: earmark,
      transaction: transaction, analysis: analysis, investment: investment,
      reporting: reporting
    )
  }

  // MARK: - Insight narrator

  /// Selects the narrator injected into `InsightStore` at launch.
  ///
  /// Precedence (both conditions must be true to use the real model):
  /// 1. The `insightsNarrationEnabled` kill-switch in `UserDefaults.moolahShared`
  ///    is on. An **absent** key is treated as `true` (the default is on), so
  ///    first-launch users get the feature without an explicit opt-in write.
  ///    `UserDefaults.bool(forKey:)` returns `false` for absent keys, so we
  ///    check `object(forKey:) == nil` first to distinguish "absent" from "off".
  /// 2. `SystemLanguageModelAvailability` reports `.available` at launch time.
  ///    The store still gates individual narration calls on `currentAvailability`,
  ///    so a runtime availability flip is honoured even if this check passed.
  ///
  /// When either condition fails, `TemplateNarrator` is used — the store will
  /// not surface narration while the model is unavailable, but the kill-switch
  /// must also be honoured at construction time so toggling the switch off and
  /// relaunching truly stops FM narration.
  @MainActor
  static func makeInsightNarrator() -> any InsightNarrating {
    let defaults = UserDefaults.moolahShared
    let narrationKey = UserDefaults.insightsNarrationEnabledKey
    let killSwitchOn =
      defaults.object(forKey: narrationKey) == nil ? true : defaults.bool(forKey: narrationKey)
    guard killSwitchOn else { return TemplateNarrator() }
    guard SystemLanguageModelAvailability().current().isUsable else { return TemplateNarrator() }
    return FoundationModelsNarrator()
  }

}
