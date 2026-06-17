// App/ProfileSession+CatalogFactory.swift

import Foundation
import GRDB
import OSLog

extension ProfileSession {
  /// Shared on-disk location for the CoinGecko catalog and the CryptoCompare /
  /// Binance token caches — a single `InstrumentRegistry` directory under the
  /// app-group container so every catalog/cache `.sqlite` lives together.
  /// `nonisolated` so `makeLookupCatalog` (which also runs off `@MainActor`)
  /// can read it.
  nonisolated private static var instrumentRegistryDirectory: URL {
    URL.moolahScopedApplicationSupport
      .appending(path: "InstrumentRegistry", directoryHint: .isDirectory)
  }

  /// Builds the per-profile CoinGecko catalog and kicks off a background
  /// `refreshIfStale()` so the SQLite snapshot is brought up to date once per
  /// session without blocking init. Returns `(nil, nil)` (and logs) when the
  /// SQLite file can't be opened — the caller treats that as a degraded
  /// search path. The returned `refreshTask` handle is stored on
  /// `ProfileSession` so it can be cancelled on teardown.
  @MainActor
  static func makeCoinGeckoCatalog(
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices
  ) -> (catalog: (any CoinGeckoCatalog)?, refreshTask: Task<Void, Never>?) {
    let directory = Self.instrumentRegistryDirectory
    do {
      let catalog = try SQLiteCoinGeckoCatalog.make(
        directory: directory,
        apiKeyProvider: coinGeckoApiKeyProvider,
        networking: networking)
      // `SQLiteCoinGeckoCatalog` is an actor, so `await catalog.refreshIfStale()`
      // hops to the catalog's executor regardless of the enclosing Task's
      // isolation — no `Task.detached` needed (CONCURRENCY_GUIDE §8).
      let refreshTask = Task(priority: .background) { [catalog] in
        await catalog.refreshIfStale()
      }
      return (catalog, refreshTask)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error("CoinGecko catalog init failed: \(error.localizedDescription, privacy: .public)")
      return (nil, nil)
    }
  }

  /// Builds the per-profile CryptoCompare coin-list cache and kicks off a
  /// background `refreshIfStale()` so the SQLite snapshot is brought up to
  /// date once per session without blocking init. Opens `cryptocompare.sqlite`
  /// in the same `InstrumentRegistry` directory as the CoinGecko catalog.
  /// Returns `(nil, nil)` (and logs) when the SQLite file can't be opened —
  /// the caller treats that as a degraded resolution path. The returned
  /// `refreshTask` handle is stored on `ProfileSession` so it can be cancelled
  /// on teardown. The CryptoCompare key is resolved per refresh through
  /// `resolveCryptoCompareApiKey()` so a key entered in Settings takes effect
  /// on the next refresh without rebuilding the session.
  @MainActor
  static func makeCryptoCompareCache(
    networking: NetworkingServices
  ) -> (cache: CryptoCompareTokenCache?, refreshTask: Task<Void, Never>?) {
    let directory = Self.instrumentRegistryDirectory
    do {
      let cache = try CryptoCompareTokenCache.make(
        directory: directory,
        apiKeyProvider: { ProfileSession.resolveCryptoCompareApiKey() },
        networking: networking)
      // `CryptoCompareTokenCache` is an actor, so `await cache.refreshIfStale()`
      // hops to the cache's executor regardless of the enclosing Task's
      // isolation — no `Task.detached` needed (CONCURRENCY_GUIDE §8).
      let refreshTask = Task(priority: .background) { [cache] in
        await cache.refreshIfStale()
      }
      return (cache, refreshTask)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error("CryptoCompare cache init failed: \(error.localizedDescription, privacy: .public)")
      return (nil, nil)
    }
  }

  /// Builds the per-profile Binance USDT-pair cache and kicks off a background
  /// `refreshIfStale()` so the SQLite snapshot is brought up to date once per
  /// session without blocking init. Opens `binance.sqlite` in the same
  /// `InstrumentRegistry` directory as the CoinGecko catalog. Returns
  /// `(nil, nil)` (and logs) when the SQLite file can't be opened — the caller
  /// treats that as a degraded resolution path. The returned `refreshTask`
  /// handle is stored on `ProfileSession` so it can be cancelled on teardown.
  /// Binance's `exchangeInfo` endpoint is keyless, so — unlike the CryptoCompare
  /// cache — there is no API key to resolve.
  @MainActor
  static func makeBinanceCache(
    networking: NetworkingServices
  ) -> (cache: BinanceTokenCache?, refreshTask: Task<Void, Never>?) {
    let directory = Self.instrumentRegistryDirectory
    do {
      let cache = try BinanceTokenCache.make(
        directory: directory,
        networking: networking)
      // `BinanceTokenCache` is an actor, so `await cache.refreshIfStale()`
      // hops to the cache's executor regardless of the enclosing Task's
      // isolation — no `Task.detached` needed (CONCURRENCY_GUIDE §8).
      let refreshTask = Task(priority: .background) { [cache] in
        await cache.refreshIfStale()
      }
      return (cache, refreshTask)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error("Binance cache init failed: \(error.localizedDescription, privacy: .public)")
      return (nil, nil)
    }
  }

  /// Opens the local DefiLlama per-token support cache in the shared
  /// `InstrumentRegistry` directory. Unlike the list caches it starts no
  /// background `refreshIfStale()` — the startup probe in
  /// `seedBuiltInCryptoPresets` refreshes it from the registered token set.
  /// Returns `nil` (and logs) on open failure; the `DefiLlamaClient` then runs
  /// without short-circuit/floor optimisations but still prices live.
  ///
  /// Not `@MainActor`: `makeMarketDataServices` (its caller) runs both on the
  /// `@MainActor` `ProfileSession.init` path and the non-isolated app-boot
  /// `bootstrapSyncCoordinator` path, and no `Task` is spawned here.
  static func makeDefiLlamaSupportCache(
    networking: NetworkingServices
  ) -> DefiLlamaSupportCache? {
    do {
      return try DefiLlamaSupportCache.make(
        directory: Self.instrumentRegistryDirectory, networking: networking)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error(
          "DefiLlama support cache init failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Opens a read-only handle to the shared CoinGecko catalog for offline
  /// `(chain, contract) → CoinGecko id` resolution by the discovery token
  /// resolver. Unlike `makeCoinGeckoCatalog` it starts no `refreshIfStale()`
  /// task — the registry-wiring catalog owns that refresh; this handle reads
  /// the same on-disk snapshot (WAL lets a separate connection see those
  /// writes). Returns `nil` on open failure, or under UI testing where the
  /// discovery flow runs against seeded data rather than the live catalog.
  ///
  /// Not `@MainActor`: `makeMarketDataServices` (its caller) runs both on the
  /// `@MainActor` `ProfileSession.init` path and the non-isolated app-boot
  /// `bootstrapSyncCoordinator` path, and `currentUITestSeed()` reads only
  /// `CommandLine` / `ProcessInfo`.
  static func makeLookupCatalog(
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices
  ) -> (any LocalContractResolver)? {
    guard currentUITestSeed() == nil else { return nil }
    let directory = Self.instrumentRegistryDirectory
    do {
      return try SQLiteCoinGeckoCatalog.make(
        directory: directory,
        apiKeyProvider: coinGeckoApiKeyProvider,
        networking: networking)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error(
          "CoinGecko lookup catalog init failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}
