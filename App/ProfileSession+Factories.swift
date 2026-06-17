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
    let defiLlamaSupportCache: DefiLlamaSupportCache?
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
    let defiLlamaSupportCache = Self.makeDefiLlamaSupportCache(networking: networking)
    return MarketDataServices(
      exchangeRate: ExchangeRateService(
        client: FrankfurterClient(
          http: networking.client(forHost: "api.frankfurter.app")),
        database: database),
      stockPrice: StockPriceService(client: yahooClient, database: database),
      cryptoPrice: Self.makeCryptoPriceService(
        coinGeckoApiKeyProvider: cgKeyProvider, database: database, networking: networking,
        defiLlamaSupportCache: defiLlamaSupportCache,
        localResolver: lookupCatalog),
      yahooPriceFetcher: yahooClient,
      coinGeckoApiKeyProvider: cgKeyProvider,
      defiLlamaSupportCache: defiLlamaSupportCache
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
    defiLlamaSupportCache: DefiLlamaSupportCache?,
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
    let defiLlamaClient = DefiLlamaClient(
      networking: networking, supportCache: defiLlamaSupportCache)
    let priceClients: [CryptoPriceClient] = [
      defiLlamaClient,
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
