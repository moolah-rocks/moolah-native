import Foundation

/// Process-wide registry that owns one `RateLimitGate` per host (created
/// lazily on first lookup) and one `FailedRequestCache` for the process.
/// Vends `RateLimitedHTTPClient` instances bound to the requested host so
/// that two callers of the same host share a gate — a 429 from one cools
/// the other down.
///
/// Constructed once in `MoolahApp+Setup` and injected through
/// `SyncCoordinator` → `ProfileSession` → factories. Tests construct their
/// own instance with an ephemeral `URLProtocol`-backed `URLSession`, so
/// each test gets isolated gates with no global mutable state.
///
/// See `guides/CONCURRENCY_GUIDE.md` §4.
final class NetworkingServices: Sendable {
  private let session: URLSession
  private let failureCache: FailedRequestCache
  private let registry: GateRegistry

  /// - Parameter session: URLSession used for every request. Defaults to
  ///   `.shared` in production. Tests inject an ephemeral session whose
  ///   `protocolClasses` includes a `URLProtocol` stub.
  init(session: URLSession = .shared) {
    self.session = session
    self.failureCache = FailedRequestCache()
    self.registry = GateRegistry()
  }

  /// Returns a `RateLimitedHTTPClient` bound to the host's rate-limit
  /// gate and the shared failure cache. Host strings are normalised to
  /// lower-case so `Api.Example.com` and `api.example.com` share a gate.
  func client(forHost host: String) -> RateLimitedHTTPClient {
    let gate = registry.synchronousGate(forHost: host.lowercased())
    return RateLimitedHTTPClient(
      session: session, gate: gate, failureCache: failureCache)
  }

  // MARK: - Test seams (internal)

  /// Returns the gate for `host` (lower-cased internally). Same gate is
  /// returned for repeat lookups. Wraps `synchronousGate(forHost:)` with an
  /// async signature so test call sites can `await` without a cast. The
  /// underlying lookup is synchronous.
  /// Internal so `NetworkingServicesTests` can assert gate-sharing.
  func gate(forHost host: String) async -> RateLimitGate {
    await registry.gate(forHost: host.lowercased())
  }

  /// The injected `URLSession`. Internal so tests can assert pass-through.
  var underlyingSession: URLSession { session }
}

/// Actor-isolated `[String: RateLimitGate]`. Lazy creation: the registry
/// stays empty until first lookup per host. Hot path uses
/// `synchronousGate(forHost:)`, which uses a lock instead of `await` so
/// the request hot path doesn't hop to the actor just to read the gate.
private final class GateRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var gates: [String: RateLimitGate] = [:]

  /// Sync accessor used by `NetworkingServices.client(forHost:)`. The
  /// lock is uncontended in steady state (Dictionary lookup is O(1)) and
  /// avoids the actor hop on every request. The carve-out is documented
  /// on the class itself — `@unchecked Sendable` because the only mutable
  /// state is `gates`, fully guarded by `lock`.
  func synchronousGate(forHost host: String) -> RateLimitGate {
    lock.lock()
    defer { lock.unlock() }
    if let existing = gates[host] { return existing }
    let gate = RateLimitGate()
    gates[host] = gate
    return gate
  }

  /// Async accessor used only by tests asserting registry behaviour.
  func gate(forHost host: String) async -> RateLimitGate {
    synchronousGate(forHost: host)
  }
}
