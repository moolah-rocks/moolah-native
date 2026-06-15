// App/ProfileSession+CatalogFactory.swift

import Foundation
import GRDB
import OSLog

extension ProfileSession {
  /// Builds the per-profile CoinGecko catalog and kicks off a background
  /// `refreshIfStale()` so the SQLite snapshot is brought up to date once per
  /// session without blocking init. Returns `(nil, nil)` (and logs) when the
  /// SQLite file can't be opened — the caller treats that as a degraded
  /// search path. The returned `refreshTask` handle is stored on
  /// `ProfileSession` so it can be cancelled on teardown.
  @MainActor
  static func makeCoinGeckoCatalog(
    apiKey: String?,
    networking: NetworkingServices
  ) -> (catalog: (any CoinGeckoCatalog)?, refreshTask: Task<Void, Never>?) {
    let directory = URL.moolahScopedApplicationSupport
      .appending(path: "InstrumentRegistry", directoryHint: .isDirectory)
    do {
      let host = (apiKey ?? "").isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
      let catalog = try SQLiteCoinGeckoCatalog.make(
        directory: directory,
        http: networking.client(forHost: host))
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
    apiKey: String?,
    networking: NetworkingServices
  ) -> (any LocalContractResolver)? {
    guard currentUITestSeed() == nil else { return nil }
    let directory = URL.moolahScopedApplicationSupport
      .appending(path: "InstrumentRegistry", directoryHint: .isDirectory)
    do {
      let host = (apiKey ?? "").isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
      return try SQLiteCoinGeckoCatalog.make(
        directory: directory,
        http: networking.client(forHost: host))
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error(
          "CoinGecko lookup catalog init failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}
