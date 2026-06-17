import Foundation

// Built-in crypto preset seeding (#791) and the startup provider-mapping
// re-detection pass (#1140). Split out of `ProfileSession.swift` to keep that
// file within the `file_length` budget.
extension ProfileSession {
  /// Fires `registerBuiltInPresetsIfMissing` on the profile's registry
  /// so chain native gas tokens (ETH on Ethereum / OP / Base; MATIC on
  /// Polygon) and well-known ERC-20s carry a real provider mapping
  /// before any conversion path consults the registry. Without this,
  /// transaction detail / running-balance render fails for crypto legs
  /// the very first time a profile reads them — issue #791.
  ///
  /// Then runs `reconcileProviderMappings` so already-registered tokens
  /// (e.g. coingecko-only RPL / ILV / IMX) gain newly-cached Binance /
  /// CryptoCompare mappings on the next launch — deep history resolves
  /// and months stop rendering "—" (issue #1140).
  ///
  /// Both steps share one `Task` tracked in `crossStoreUpdateTasks` so
  /// `cleanupSync` cancels in-flight work when the session tears down.
  func seedBuiltInCryptoPresets(
    registry: (any InstrumentRegistryRepository)?
  ) {
    guard let registry else { return }
    let task = Task {
      await registry.registerBuiltInPresetsIfMissing()
      guard !Task.isCancelled else { return }
      await self.reconcileFromCaches(registry: registry)
      guard !Task.isCancelled else { return }
      await self.probeDefiLlamaSupport(registry: registry)
    }
    crossStoreUpdateTasks.append(task)
  }

  /// Batched DefiLlama support probe: refreshes the local support cache for the
  /// profile's registered tokens so the `DefiLlamaClient` can short-circuit
  /// known-unsupported tokens and bound backfills at each token's history floor
  /// (#1140 follow-on). Best-effort; skipped if the cache failed to open.
  private func probeDefiLlamaSupport(
    registry: any InstrumentRegistryRepository
  ) async {
    guard let defiLlamaSupportCache else { return }
    let registrations: [CryptoRegistration]
    do {
      registrations = try await registry.allCryptoRegistrations()
    } catch {
      return  // best-effort; next launch retries
    }
    await defiLlamaSupportCache.refreshSupport(for: registrations, now: Date())
  }

  /// Re-detection pass: upgrade already-registered tokens (e.g.
  /// coingecko-only RPL / ILV / IMX) with newly-cached Binance /
  /// CryptoCompare mappings so deep history resolves and months stop
  /// rendering "—" (issue #1140). Requires both provider caches; skipped
  /// if either is unavailable (degraded open). CoinGecko ids are already
  /// resolved at registration time, so the CoinGecko resolver is optional —
  /// the live `SQLiteCoinGeckoCatalog` also conforms to
  /// `LocalContractResolver`, so it is passed when the down-cast succeeds.
  private func reconcileFromCaches(
    registry: any InstrumentRegistryRepository
  ) async {
    guard let cryptoCompareCache, let binanceCache else { return }
    let lookups = ProviderCatalogLookups(
      cryptoCompare: cryptoCompareCache,
      binance: binanceCache,
      coinGecko: coinGeckoCatalog as? any LocalContractResolver)
    await registry.reconcileProviderMappings(using: lookups)
  }
}
