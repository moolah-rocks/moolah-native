// MoolahTests/Shared/CryptoImport/RPCEndpointResolverResetTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `RPCEndpointResolver.reset(customEndpoints:)` — the mid-session
/// re-point that lets a Settings edit reach wallet-sync routing without an app
/// relaunch. In its own `@Suite`/file (with a self-contained harness) so the
/// core `RPCEndpointResolverTests` type stays under the body-length limit and
/// merge-queue conflicts between the two areas stay isolated.
@Suite("RPCEndpointResolver reset", .serialized)
struct RPCEndpointResolverResetTests {
  private static let customEndpoint = "https://op.custom.test"
  private static let second = "https://second.custom.test"

  /// Builds a resolver over an ephemeral session backed by the dedicated stub,
  /// plus a `RequestRecorder` for asserting how many `eth_chainId` calls went
  /// out per endpoint. `handler` is a named argument (not trailing) so passing
  /// it alongside `alchemyKeyPresent` stays a single-closure call site.
  private func makeResolver(
    customEndpoints: [String],
    alchemyKeyPresent: @escaping @Sendable () -> Bool = { false },
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> (RPCEndpointResolver, RequestRecorder) {
    let recorder = RequestRecorder()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RPCEndpointResolverResetURLProtocolStub.self]
    let session = URLSession(configuration: config)
    RPCEndpointResolverResetURLProtocolStub.requestHandler = { request in
      recorder.record(request.url?.absoluteString ?? "")
      return try handler(request)
    }
    let resolver = RPCEndpointResolver(
      customEndpoints: customEndpoints,
      alchemyKeyPresent: alchemyKeyPresent,
      makeRPC: { url in
        LiveJSONRPCClient(
          endpoint: url,
          session: session,
          rateLimiter: RateLimiter(permitsPerSecond: 1_000),
          sleeper: { _ in })
      })
    return (resolver, recorder)
  }

  /// Scripts `eth_chainId` per endpoint: `op.custom.test` → chain 10 (OP),
  /// `second.custom.test` → chain 8453 (Base). Any other URL is a
  /// test-authoring mistake — HTTP 404 makes that loud.
  private func chainIdHandler(_ request: URLRequest) -> (HTTPURLResponse, Data) {
    switch request.url?.absoluteString {
    case Self.customEndpoint:
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0xa"}"#.utf8)
      )
    case Self.second:
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x2105"}"#.utf8)
      )
    default:
      return (AlchemyTestSupport.response(for: request, statusCode: 404), Data())
    }
  }

  @Test
  func resetSwitchesRoutingToTheNewEndpointList() async throws {
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.customEndpoint],
      alchemyKeyPresent: { false },
      handler: chainIdHandler)

    // Warm the original list: OP Mainnet (chain 10) routes to the custom node.
    let before = await resolver.client(for: .optimism)
    guard case .direct = before else {
      Issue.record("Expected .direct before reset, got \(before)")
      return
    }

    // Swap the list to a Base-only endpoint (chain 8453).
    await resolver.reset(customEndpoints: [Self.second])

    // Base now resolves via the new endpoint …
    let base = await resolver.client(for: .base)
    guard case .direct(let baseClient) = base else {
      Issue.record("Expected .direct for Base after reset, got \(base)")
      return
    }
    let baseChainId = try await baseClient.chainId()
    #expect(baseChainId == 8453)

    // … and the removed OP endpoint no longer matches: with no Alchemy key,
    // Optimism falls through to its default publicnode client (which the stub
    // 404s), so probing it throws rather than returning chain 10.
    let opAfter = await resolver.client(for: .optimism)
    guard case .direct(let opClient) = opAfter else {
      Issue.record("Expected .direct (default publicnode) for OP after reset, got \(opAfter)")
      return
    }
    await #expect(throws: (any Error).self) { try await opClient.chainId() }
  }

  @Test
  func resetClearsCachedProbesSoEndpointsAreReProbed() async throws {
    let (resolver, recorder) = makeResolver(
      customEndpoints: [Self.customEndpoint], handler: chainIdHandler)

    _ = await resolver.client(for: .optimism)
    #expect(recorder.count(for: Self.customEndpoint) == 1)

    // Resetting to the same list must drop the cached probe, so the next
    // resolution re-issues `eth_chainId` rather than serving the stale cache.
    await resolver.reset(customEndpoints: [Self.customEndpoint])
    _ = await resolver.client(for: .optimism)
    #expect(recorder.count(for: Self.customEndpoint) == 2)
  }

  @Test
  func supersededProbeResumeDoesNotCorruptCacheAfterReset() async throws {
    let gate = ProbeGate()
    let (resolver, recorder) = makeResolver(
      customEndpoints: [Self.customEndpoint],
      handler: { [chainIdHandler] request in
        gate.gateFirstCall()
        return chainIdHandler(request)
      })

    // Start the probe that `reset` will race with, on its own task. Its
    // `eth_chainId` response is parked on `gate` — synchronously, inside
    // the stub's `startLoading()` — until the test releases it below.
    let staleTask = Task { await resolver.client(for: .optimism) }

    // Wait for the stale probe's request to actually reach the stub before
    // racing a reset against it, so the reset is guaranteed to land while
    // the probe is genuinely in flight — not before it starts. `startLoading()`
    // runs on `URLSession`'s own loading thread, not the Swift concurrency
    // cooperative pool, so blocking it here is safe and doesn't starve
    // anything `await`ing elsewhere.
    gate.waitUntilFirstCallEntered()

    // `reset` has no `await` in its body, so it runs to completion
    // atomically on the actor while the stale probe is parked on the
    // network — it wins the race and clears `cache`/`parsedURLs`/`inFlight`
    // out from under it. The same endpoint stays in the list.
    await resolver.reset(customEndpoints: [Self.customEndpoint])

    // Release the stale probe. Its `eth_chainId` result (chain 10,
    // matching Optimism) now resumes into a resolver state a `reset` has
    // already superseded.
    gate.releaseFirstCall()
    _ = await staleTask.value
    // This raced call may legitimately fall back to Alchemy/default per the
    // bug's own documented behaviour — the point of this test is what
    // happens *next*, not this call's own result.

    // The real assertion: the endpoint is still present after the reset,
    // so the superseded resume must not have left the resolver stuck with
    // a `cache` entry that has no matching `parsedURLs` entry (the
    // pre-fix bug — a stale probe resume wrote `cache[endpoint]` after
    // `reset` had already cleared `parsedURLs`, so `client(for:)` could
    // never again match the cached probe back to a `URL` and silently fell
    // through to Alchemy/default until another reset). A fresh probe must
    // repopulate both `cache` and `parsedURLs` — evidenced by exactly one
    // more request reaching the endpoint (the stale probe plus this fresh
    // re-probe, and no third redundant probe).
    let healed = await resolver.client(for: .optimism)
    #expect(recorder.count(for: Self.customEndpoint) == 2)
    guard case .direct(let client) = healed else {
      Issue.record("Expected .direct after reset healed, got \(healed)")
      return
    }

    // And the resolved client is genuinely the custom endpoint (not the
    // default publicnode, which the stub 404s) — the chain ID round-trips.
    let chainId = try await client.chainId()
    #expect(chainId == 10)
  }

  @Test
  func resetToEmptyListWithAlchemyKeyRoutesEveryChainToAlchemy() async throws {
    // The behaviour invariant: no custom endpoint + Alchemy key present must
    // resolve `.alchemy` for every chain, identical to construction time.
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.customEndpoint],
      alchemyKeyPresent: { true },
      handler: chainIdHandler)
    _ = await resolver.client(for: .optimism)

    await resolver.reset(customEndpoints: [])
    for chain in [ChainConfig.ethereum, .optimism, .base] {
      let resolved = await resolver.client(for: chain)
      guard case .alchemy = resolved else {
        Issue.record("Expected .alchemy for \(chain.chainId) after reset([]), got \(resolved)")
        return
      }
    }
  }
}

/// Thread-safe recorder for the URLProtocol handler closure (which must be
/// `@Sendable`), tracking every request URL so a test can assert a per-endpoint
/// call count (proving cache invalidation actually forced a re-probe).
private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [String] = []

  func record(_ url: String) {
    lock.lock()
    defer { lock.unlock() }
    urls.append(url)
  }

  func count(for url: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return urls.filter { $0 == url }.count
  }
}

/// Dedicated `URLProtocol` stub for this suite, with its own static handler
/// state so it cannot race other suites' stubs. `nonisolated(unsafe)` is safe
/// because the enclosing `@Suite` is `.serialized`: the handler is assigned in
/// `makeResolver` before any stub invocation, and no two tests run concurrently.
private final class RPCEndpointResolverResetURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = RPCEndpointResolverResetURLProtocolStub.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

/// Lets `supersededProbeResumeDoesNotCorruptCacheAfterReset` suspend the
/// stale probe's `eth_chainId` response until it has raced a
/// `reset(customEndpoints:)` against it — removing the fetch-vs-reset
/// ordering race from the test itself. Only the *first* call actually
/// parks: once `releaseFirstCall()` has run, later calls (the fresh,
/// post-reset probe) return immediately, so exactly one request is gated
/// per test. Uses `DispatchSemaphore`, not an async continuation, because
/// the request handler closure the stub invokes from `startLoading()` is
/// synchronous — that call runs on `URLSession`'s own loading thread, not
/// the Swift concurrency cooperative pool, so blocking it here is safe.
private final class ProbeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  /// Called from the stub's request handler: blocks only the first call
  /// through the gate until `releaseFirstCall()`; every later call no-ops.
  func gateFirstCall() {
    lock.lock()
    callCount += 1
    let isFirst = callCount == 1
    lock.unlock()
    guard isFirst else { return }
    entered.signal()
    release.wait()
  }

  /// Called by the test: blocks until the first call has reached the gate.
  func waitUntilFirstCallEntered() {
    entered.wait()
  }

  /// Called by the test: unparks the first call.
  func releaseFirstCall() {
    release.signal()
  }
}
