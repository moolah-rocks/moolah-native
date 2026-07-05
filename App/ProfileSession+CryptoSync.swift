// App/ProfileSession+CryptoSync.swift
import Foundation
import OSLog

extension ProfileSession {
  /// Returns the live Alchemy API key from the keychain, or `nil` when no
  /// key is configured. Read-only here; the settings UI owns the
  /// write side. Service / account strings are pinned to the values
  /// the settings UI writes against so both ends target the same
  /// keychain entry.
  ///
  /// `nonisolated` so it can be called from the `@Sendable` closure that
  /// `LiveAlchemyClient` uses to resolve the key per-request — the work
  /// itself is just a synchronous Keychain read, so it doesn't need
  /// `@MainActor` isolation that the surrounding `ProfileSession`
  /// extension inherits.
  ///
  /// Under UI testing, `UITestEnvironment.alchemyKeyPresent == "1"` in
  /// the launch environment causes this function to return a synthetic
  /// placeholder rather than reading the system keychain. A real
  /// `SecItemCopyMatching(synchronizable: true)` call from a background
  /// task can trigger an iCloud authorization dialog on the main thread,
  /// which blocks the app's run loop indefinitely in a headless CI
  /// environment. The placeholder value is non-nil (so the `LiveAlchemyClient`
  /// takes the authenticated path) but will produce an HTTP 401 error on
  /// the first Alchemy request; the resulting `invalidApiKey` error is
  /// recorded to `WalletSyncState` and surfaces as an inline caption —
  /// the same UI path that UI tests for this seed exercise.
  nonisolated static func resolveAlchemyApiKey() -> String? {
    if ProcessInfo.processInfo.environment[UITestEnvironment.alchemyKeyPresent] == "1" {
      return "ui-test-placeholder"
    }
    let store = KeychainStore(
      service: KeychainServices.apiKeys, account: "alchemy", synchronizable: true)
    do {
      return try store.restoreString()
    } catch {
      logger.error(
        "Alchemy keychain read failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Returns the live CoinGecko API key from the keychain, or `nil` when no
  /// key is configured. `nonisolated` so the `@Sendable` key-provider closure
  /// threaded into the CoinGecko price client, token resolver, and discovery
  /// catalog can resolve it per request — a Pro key entered in Settings then
  /// flips every consumer from the free public host to the authenticated Pro
  /// host on the next fetch without rebuilding the session.
  nonisolated static func resolveCoinGeckoApiKey() -> String? {
    let store = KeychainStore(
      service: KeychainServices.apiKeys, account: "coingecko", synchronizable: true)
    do {
      return try store.restoreString()
    } catch {
      logger.error(
        "CoinGecko keychain read failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Output of `makeCryptoSyncWiring`. The discovery actor is plumbed
  /// out alongside the store so the Discovered Tokens inbox can drive
  /// `reResolve(_:chain:)` on the same actor instance the sync engine
  /// uses — this preserves the in-flight coalescer's "one round-trip
  /// per `(chainId, contractAddress)`" guarantee across the manual +
  /// automatic re-resolution paths.
  struct CryptoSyncWiring {
    let store: SyncedAccountStore
    let discovery: CryptoTokenDiscoveryService
  }

  /// Builds the `SyncedAccountStore` (and exposes the underlying
  /// `CryptoTokenDiscoveryService`) for a profile, registering the
  /// wallet + Coinstash sync sources. Returns `nil` when the profile
  /// has no `instrumentRegistry` (preview / degraded launches); the
  /// auto-import feature is unavailable in that mode.
  ///
  /// Live wiring uses:
  ///
  /// - `RateLimiter(permitsPerSecond: 5, burstCapacity: 1)` for Alchemy.
  ///   `burstCapacity: 1` strictly spaces calls ~200ms apart so the
  ///   launch-time fan-out across every crypto account (all sharing this one
  ///   limiter and client) can't fire simultaneously and trip Alchemy's
  ///   per-second burst cap — the free tier rejects the burst, not the
  ///   volume. Steady 5 req/s stays well under the sustained ceiling.
  /// - `RateLimiter(permitsPerSecond: 5)` for Blockscout public
  ///   unauthenticated tier (~5 req/s per IP).
  /// - `LiveAlchemyClient` — same shape as `Backends/CoinGecko/CoinGeckoClient`.
  /// - `LiveBlockscoutClient` — authoritative native + internal ETH index.
  /// - `CryptoTokenDiscoveryService` — actor-coalesced registry resolver.
  /// - `WalletSyncEngine` — read-only build orchestrator for wallet sync.
  /// - `WalletApplyEngine` — `@MainActor` apply pass with
  ///   `NoOpWalletImportRulesEngine`.
  ///
  /// The keychain read is best-effort: the live `LiveAlchemyClient` is
  /// constructed even when the key is missing or empty so the build
  /// phase throws a typed `.invalidApiKey` (HTTP 401/403) on the first
  /// account, the store records it, and the user sees a banner asking
  /// them to set the key. This avoids a `nil`-AlchemyClient branch that
  /// would silently skip every crypto account.
  @MainActor
  static func makeCryptoSyncWiring(
    backend: BackendProvider,
    registry: (any InstrumentRegistryRepository)?,
    cryptoPriceService: CryptoPriceService,
    profileInstrument: Instrument,
    canonicalResolver: CanonicalInstrumentResolver = CanonicalInstrumentResolver()
  ) -> CryptoSyncWiring? {
    guard let registry else { return nil }
    let rateLimiter = RateLimiter(permitsPerSecond: 5, burstCapacity: 1)
    let alchemy: any AlchemyClient = LiveAlchemyClient(
      // Closure (not a resolved value): a key entered in Settings after this
      // wiring is built is visible on the next sync cycle without a rebuild,
      // and the key never lives on the client object itself.
      apiKeyProvider: { ProfileSession.resolveAlchemyApiKey() },
      rateLimiter: rateLimiter)
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: cryptoPriceService, canonicalResolver: canonicalResolver)
    let walletSyncEngine = makeWalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: makeLiveBlockExplorer(),
      discovery: discovery,
      backend: backend)
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine())
    let coinstashSource = makeCoinstashSource(
      registry: registry,
      fiatInstrument: profileInstrument,
      backend: backend,
      discovery: discovery)
    let transferDetection = TransferDetectionCoordinator(
      transactions: backend.transactions,
      suggestions: backend.transferSuggestions)
    let priceWarmer = CryptoPriceWarmer(
      priceService: cryptoPriceService,
      registrations: { try await registry.allCryptoRegistrations() })
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine), coinstashSource],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: transferDetection,
      priceWarmer: priceWarmer)
    return CryptoSyncWiring(store: store, discovery: discovery)
  }

  @MainActor
  private static func makeLiveBlockExplorer() -> any BlockExplorerClient {
    // Blockscout public unauthenticated tier: ~5 req/s per IP.
    LiveBlockscoutClient(rateLimiter: RateLimiter(permitsPerSecond: 5))
  }

  @MainActor
  private static func makeWalletSyncEngine(
    alchemy: any AlchemyClient,
    blockExplorer: any BlockExplorerClient,
    discovery: CryptoTokenDiscoveryService,
    backend: BackendProvider
  ) -> WalletSyncEngine {
    let importOriginFactory: @Sendable (UUID) -> ImportOrigin = { accountId in
      ImportOrigin(
        rawDescription: "wallet:\(accountId.uuidString)",
        rawAmount: 0,
        importedAt: Date(),
        importSessionId: UUID(),
        parserIdentifier: BackgroundSyncSource.wallet.parserIdentifier)
    }
    return WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: importOriginFactory)
  }

  @MainActor
  private static func makeCoinstashSource(
    registry: any InstrumentRegistryRepository,
    fiatInstrument: Instrument,
    backend: BackendProvider,
    discovery: CryptoTokenDiscoveryService
  ) -> CoinstashSyncSource {
    let coinstashClient = CoinstashClient()
    let txRepo = backend.transactions
    // Per-account-pass origin. Mirrors the wallet factory in
    // `makeWalletSyncEngine` so Coinstash imports show up in
    // `RecentlyAddedView` (which short-circuits on a nil `singleOrigin`)
    // and group as one import session. Explicitly `@Sendable` for parity
    // with the wallet site — keeps the Sendable constraint visible at
    // the binding so a future captured variable trips the compiler
    // rather than silently losing the guarantee.
    let importOriginFactory: @Sendable (UUID) -> ImportOrigin = { accountId in
      ImportOrigin(
        rawDescription: "exchange:\(accountId.uuidString)",
        rawAmount: 0,
        importedAt: Date(),
        importSessionId: UUID(),
        parserIdentifier: BackgroundSyncSource.coinstash.parserIdentifier)
    }
    return CoinstashSyncSource(
      tokenStore: ExchangeTokenStore(synchronizable: true),
      client: coinstashClient,
      engine: ExchangeSyncEngine(
        resolver: ExchangeInstrumentResolver(
          registry: registry,
          // The profile's own currency, NOT a hardcoded `.AUD` — a
          // non-AUD profile would otherwise mis-denominate.
          fiatInstrument: fiatInstrument,
          existingLegInstrumentIds: {
            do {
              return try await txRepo.distinctLegInstrumentIds()
            } catch {
              Self.logger.error(
                "distinctLegInstrumentIds failed: \(error, privacy: .public)")
              throw error
            }
          }),
        discovery: discovery,
        importOriginFactory: importOriginFactory),
      metadataResolverFactory: { token in
        CoinstashAssetMetadataResolver(client: coinstashClient, token: token)
      })
  }

  nonisolated private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoSyncWiring")
}
