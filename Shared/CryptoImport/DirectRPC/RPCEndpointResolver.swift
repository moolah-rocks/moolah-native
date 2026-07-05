// Shared/CryptoImport/DirectRPC/RPCEndpointResolver.swift
import Foundation

/// Resolves, per chain, which JSON-RPC client should serve it: a
/// user-supplied custom endpoint (matched by probing `eth_chainId`) takes
/// precedence over Alchemy, which takes precedence over the chain's default
/// public node.
///
/// Also serves the Settings screen's "probe my custom endpoints" affordance
/// (`probeAll()`), so a user can see which of their configured endpoints are
/// reachable and which chain each one actually serves.
///
/// An `actor` because both entry points mutate a shared probe cache, and
/// callers can legitimately call from concurrent contexts (Settings probing
/// while a sync session is routing chains). Concurrent calls that name the
/// same not-yet-probed endpoint share one in-flight `eth_chainId` round trip
/// rather than each issuing their own — mirroring `TokenMetadataResolver`'s
/// in-flight-`Task` coalescing.
actor RPCEndpointResolver {
  /// Result of probing one custom endpoint's `eth_chainId`.
  struct Probe: Sendable, Equatable {
    /// The endpoint string as configured by the user (not a parsed `URL`),
    /// so an unparseable string still round-trips into a reportable result.
    let url: String
    let reachable: Bool
    let chainId: Int?
  }

  /// Which client `client(for:)` resolved for a chain.
  enum ResolvedClient: Sendable {
    case direct(LiveJSONRPCClient)
    case alchemy
  }

  private let customEndpoints: [String]
  private let alchemyKeyPresent: @Sendable () -> Bool
  private let makeRPC: @Sendable (URL) -> LiveJSONRPCClient

  /// Cached probe result per endpoint string. A probe failure (unreachable,
  /// malformed URL, thrown error) is cached as `reachable: false` too,
  /// deliberately — unlike `TokenMetadataResolver`'s transient/permanent
  /// distinction, a custom RPC endpoint that fails once is not retried
  /// within this resolver's lifetime; the Settings screen re-probes by
  /// creating a new resolver (or the user fixing the endpoint triggers a
  /// fresh app-state read that does the same).
  private var cache: [String: Probe] = [:]
  /// In-flight probe per endpoint, so concurrent callers for the same
  /// not-yet-cached endpoint share one underlying `eth_chainId` round trip
  /// instead of each starting their own. Populated before the first
  /// `await`, so a second caller arriving while the first is still running
  /// sees the in-flight task rather than racing past it.
  private var inFlight: [String: Task<Probe, Never>] = [:]

  /// - Parameters:
  ///   - customEndpoints: User-configured JSON-RPC endpoint strings, in
  ///     display/preference order. `client(for:)` matches the first one
  ///     whose probed chain ID equals the requested chain.
  ///   - alchemyKeyPresent: Checked at resolution time (not captured once),
  ///     so a key added after this resolver was constructed is honoured on
  ///     the next `client(for:)` call.
  ///   - makeRPC: Builds a `LiveJSONRPCClient` for a given endpoint `URL`.
  ///     Used both to probe custom endpoints and to build the client
  ///     `client(for:)` ultimately returns.
  init(
    customEndpoints: [String],
    alchemyKeyPresent: @escaping @Sendable () -> Bool,
    makeRPC: @escaping @Sendable (URL) -> LiveJSONRPCClient
  ) {
    self.customEndpoints = customEndpoints
    self.alchemyKeyPresent = alchemyKeyPresent
    self.makeRPC = makeRPC
  }

  /// Probes every custom endpoint's `eth_chainId`, in `customEndpoints`
  /// order, for the Settings screen. Each endpoint is probed at most once
  /// per resolver instance — repeat calls return the cached result.
  func probeAll() async -> [Probe] {
    var probes: [Probe] = []
    probes.reserveCapacity(customEndpoints.count)
    for endpoint in customEndpoints {
      probes.append(await probe(endpoint))
    }
    return probes
  }

  /// Which client should serve `chain`: the first custom endpoint (in
  /// configured order) whose probed `chainId` matches, else Alchemy if a key
  /// is present, else `chain`'s default public node.
  func client(for chain: ChainConfig) async -> ResolvedClient {
    for endpoint in customEndpoints {
      let probe = await probe(endpoint)
      if let chainId = probe.chainId, chainId == chain.chainId, let url = URL(string: endpoint) {
        return .direct(makeRPC(url))
      }
    }
    if alchemyKeyPresent() {
      return .alchemy
    }
    return .direct(makeRPC(chain.defaultRPCURL))
  }

  /// Returns the cached probe for `endpoint`, coalescing concurrent
  /// first-probes for the same endpoint into one `eth_chainId` call. An
  /// unparseable endpoint string never reaches the network — it's cached as
  /// unreachable synchronously.
  private func probe(_ endpoint: String) async -> Probe {
    if let cached = cache[endpoint] {
      return cached
    }
    if let pending = inFlight[endpoint] {
      return await pending.value
    }
    guard let url = URL(string: endpoint) else {
      let probe = Probe(url: endpoint, reachable: false, chainId: nil)
      cache[endpoint] = probe
      return probe
    }
    let makeRPC = self.makeRPC
    let task = Task { () -> Probe in
      let client = makeRPC(url)
      do {
        let chainId = try await client.chainId()
        return Probe(url: endpoint, reachable: true, chainId: chainId)
      } catch {
        return Probe(url: endpoint, reachable: false, chainId: nil)
      }
    }
    inFlight[endpoint] = task
    let probe = await task.value
    inFlight[endpoint] = nil
    cache[endpoint] = probe
    return probe
  }
}
