// Features/Settings/CryptoTokenStore+RPCEndpoints.swift
import Foundation

/// Custom JSON-RPC endpoint list surface for `CryptoTokenStore` — backs the
/// Crypto preferences tab's "Custom RPC Endpoints" section. Split into its
/// own file so the core store stays under the file-length limit; every
/// member proxies `rpcEndpointsStore` and mutates only the cached
/// `rpcEndpoints`/`rpcProbes` state declared on the core type (extensions
/// cannot add stored properties).
///
/// **When does a saved change take effect?** `rpcEndpoints` (and the
/// probe status shown in Settings) update immediately — `addRPCEndpoint`/
/// `removeRPCEndpoint` mutate the cached array synchronously and
/// `probeEndpoints()` always builds a fresh `RPCEndpointResolver` from the
/// current list. Wallet-sync *routing*, however, is wired once per
/// `ProfileSession` — `ProfileSession.makeCryptoSyncWiring` reads
/// `CryptoRPCEndpointsStore().load()` a single time when it builds the
/// resolver that `RoutingChainDataClient` uses for the rest of the
/// session. So a saved endpoint change is picked up by the Settings
/// probe right away, but by wallet sync only the next time that wiring
/// is constructed — the next app launch or profile activation. This is a
/// deliberate scope decision for an advanced, opt-in setting rather than
/// a limitation to route around: rebuilding the live sync wiring
/// mid-session would need to reach into `ProfileSession`'s stored
/// `cryptoSyncStore`/`cryptoTokenDiscovery` and any in-flight sync task,
/// which is a bigger, riskier change than this Settings-only section
/// warrants.
extension CryptoTokenStore {

  /// Adds `url` to the persisted custom endpoint list. Trims surrounding
  /// whitespace (mirrors `saveAlchemyApiKey`'s convention); an all-whitespace
  /// or already-present (post-trim) input is a no-op — duplicates would
  /// collide on the same accessibility identifier and status badge, and
  /// `RPCEndpointResolver` gains nothing from probing the same URL twice.
  func addRPCEndpoint(_ url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !rpcEndpoints.contains(trimmed) else { return }
    rpcEndpoints.append(trimmed)
    persistRPCEndpoints()
  }

  /// Removes `url` from the persisted custom endpoint list. Matches by
  /// exact string equality — the same value `addRPCEndpoint` stored and
  /// the view's `ForEach` keys rows by.
  func removeRPCEndpoint(_ url: String) {
    rpcEndpoints.removeAll { $0 == url }
    persistRPCEndpoints()
  }

  /// Probes every configured custom endpoint's `eth_chainId`, refreshing
  /// `rpcProbes` for the Settings screen's per-row status badge.
  ///
  /// A fresh `RPCEndpointResolver` is built on every call rather than
  /// reused, so an endpoint added or removed since the last probe is
  /// reflected immediately — the resolver's own per-endpoint cache only
  /// needs to help within a single probe pass, not across calls.
  ///
  /// `rpcProbeOverride`, when set, bypasses the live resolver entirely —
  /// see its declaration on `CryptoTokenStore` for why (store-level tests
  /// need deterministic results without a network round trip).
  ///
  /// Under UI testing, `UITestEnvironment.rpcProbeStubbedReachable` may be
  /// set in the launch environment as a network-free signal that every
  /// configured endpoint should probe as reachable on chain 1 (Ethereum)
  /// — the same "env var instead of real I/O" shape as `hasAlchemyApiKey`.
  func probeEndpoints() async {
    if let override = rpcProbeOverride {
      rpcProbes = await override(rpcEndpoints)
      return
    }
    if ProcessInfo.processInfo.environment[UITestEnvironment.rpcProbeStubbedReachable] == "1" {
      rpcProbes = rpcEndpoints.map {
        RPCEndpointResolver.Probe(url: $0, reachable: true, chainId: 1)
      }
      return
    }
    let endpoints = rpcEndpoints
    // Snapshotted rather than captured as a closure over `self`:
    // `hasAlchemyApiKey` is `@MainActor`-isolated, but
    // `RPCEndpointResolver.init` requires a synchronous, non-isolated
    // `@Sendable` closure. Reading it here (already on the main actor)
    // and capturing the plain `Bool` avoids an isolation mismatch; the
    // resolver is rebuilt from scratch on every `probeEndpoints()` call
    // anyway, so a key added mid-session is reflected on the next probe.
    let alchemyPresent = hasAlchemyApiKey
    let resolver = RPCEndpointResolver(
      customEndpoints: endpoints,
      alchemyKeyPresent: { alchemyPresent },
      makeRPC: { LiveJSONRPCClient(endpoint: $0, rateLimiter: RateLimiter(permitsPerSecond: 5)) }
    )
    rpcProbes = await resolver.probeAll()
  }

  /// Persists the current `rpcEndpoints` to `rpcEndpointsStore`. Sets
  /// `error` (without logging the endpoint URLs themselves — they can
  /// carry an embedded API key) on failure, mirroring
  /// `saveAlchemyApiKey`'s error-surfacing shape.
  private func persistRPCEndpoints() {
    do {
      try rpcEndpointsStore.save(rpcEndpoints)
      setError(nil)
    } catch {
      logger.error(
        "Failed to save RPC endpoint list: \(error.localizedDescription, privacy: .public)")
      setError("Failed to save RPC endpoint: \(error.localizedDescription)")
    }
  }
}
