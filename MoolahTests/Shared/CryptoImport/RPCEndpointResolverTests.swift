// MoolahTests/Shared/CryptoImport/RPCEndpointResolverTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `RPCEndpointResolver`'s two responsibilities: probing each
/// custom endpoint's `eth_chainId` (cached, for the Settings screen), and
/// routing a given `ChainConfig` to whichever client should serve it —
/// a matching custom endpoint first, then Alchemy, then the chain's default
/// publicnode endpoint.
@Suite("RPCEndpointResolver", .serialized)
struct RPCEndpointResolverTests {
  private static let customEndpoint = "https://op.custom.test"
  private static let unreachableEndpoint = "https://bad.custom.test"

  /// Builds a resolver whose `makeRPC` constructs real `LiveJSONRPCClient`s
  /// over an ephemeral session backed by the dedicated stub, and a
  /// `RequestRecorder` the test can inspect to assert how many `eth_chainId`
  /// calls actually went out per endpoint.
  private func makeResolver(
    customEndpoints: [String],
    alchemyKeyPresent: @escaping @Sendable () -> Bool = { false },
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> (RPCEndpointResolver, RequestRecorder) {
    let recorder = RequestRecorder()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RPCEndpointResolverURLProtocolStub.self]
    let session = URLSession(configuration: config)
    RPCEndpointResolverURLProtocolStub.requestHandler = { request in
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

  /// Scripts `eth_chainId` responses per endpoint URL: `op.custom.test` →
  /// chain 10 (OP Mainnet), Ethereum's default publicnode URL → chain 1.
  /// Any other URL is a test-authoring mistake — HTTP 404 makes that loud.
  private func chainIdHandler(_ request: URLRequest) -> (HTTPURLResponse, Data) {
    switch request.url?.absoluteString {
    case Self.customEndpoint:
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0xa"}"#.utf8)
      )
    case ChainConfig.ethereum.defaultRPCURL.absoluteString:
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#.utf8)
      )
    default:
      return (AlchemyTestSupport.response(for: request, statusCode: 404), Data())
    }
  }

  @Test
  func matchingCustomEndpointRoutesDirect() async throws {
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.customEndpoint], handler: chainIdHandler)
    let resolved = await resolver.client(for: .optimism)
    guard case .direct(let client) = resolved else {
      Issue.record("Expected .direct, got \(resolved)")
      return
    }
    // Confirm it's the custom endpoint's client (scripted chain 10), not
    // some other client that happens to also be `.direct`.
    let chainId = try await client.chainId()
    #expect(chainId == 10)
  }

  @Test
  func nonMatchingChainWithAlchemyKeyRoutesAlchemy() async throws {
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.customEndpoint],
      alchemyKeyPresent: { true },
      handler: chainIdHandler)
    let resolved = await resolver.client(for: .ethereum)
    guard case .alchemy = resolved else {
      Issue.record("Expected .alchemy, got \(resolved)")
      return
    }
  }

  @Test
  func nonMatchingChainWithoutAlchemyKeyRoutesDefaultPublicnode() async throws {
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.customEndpoint],
      alchemyKeyPresent: { false },
      handler: chainIdHandler)
    let resolved = await resolver.client(for: .ethereum)
    guard case .direct(let client) = resolved else {
      Issue.record("Expected .direct, got \(resolved)")
      return
    }
    // Confirm it's Ethereum's default publicnode client (scripted chain 1),
    // not the custom OP endpoint.
    let chainId = try await client.chainId()
    #expect(chainId == 1)
  }

  @Test
  func unreachableCustomEndpointIsMarkedUnreachableAndIgnoredForRouting() async throws {
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.unreachableEndpoint],
      alchemyKeyPresent: { false },
      handler: { request in
        (AlchemyTestSupport.response(for: request, statusCode: 500), Data())
      })
    let probes = await resolver.probeAll()
    #expect(
      probes == [Probe(url: Self.unreachableEndpoint, reachable: false, chainId: nil)])

    // `client(for:)` can't match the unreachable endpoint to any chain, so
    // it falls through to the default publicnode endpoint. Route Optimism
    // (chain 10) — the unreachable endpoint's probe never yields a chainId,
    // so it can't spuriously match.
    let resolved = await resolver.client(for: .optimism)
    guard case .direct = resolved else {
      Issue.record("Expected .direct (default publicnode fallback), got \(resolved)")
      return
    }
  }

  @Test
  func malformedEndpointStringDoesNotCrashAndIsMarkedUnreachable() async throws {
    // An empty string is one of the few inputs `URL(string:)` reliably
    // returns `nil` for across Foundation versions (the modern RFC
    // 3986-ish parser percent-encodes almost anything else, including
    // spaces, into a "valid" URL).
    let malformed = ""
    let (resolver, recorder) = makeResolver(
      customEndpoints: [malformed], handler: chainIdHandler)
    let probes = await resolver.probeAll()
    #expect(probes == [Probe(url: malformed, reachable: false, chainId: nil)])
    // Never even attempted a network call for an unparseable endpoint.
    #expect(recorder.total == 0)
  }

  @Test
  func probeAllPreservesCustomEndpointOrder() async throws {
    let second = "https://second.custom.test"
    let (resolver, _) = makeResolver(
      customEndpoints: [Self.customEndpoint, second]
    ) { request in
      switch request.url?.absoluteString {
      case Self.customEndpoint:
        return (
          AlchemyTestSupport.okResponse(for: request),
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0xa"}"#.utf8)
        )
      case second:
        return (
          AlchemyTestSupport.okResponse(for: request),
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0x2105"}"#.utf8)
        )
      default:
        return (AlchemyTestSupport.response(for: request, statusCode: 404), Data())
      }
    }
    let probes = await resolver.probeAll()
    #expect(
      probes == [
        Probe(url: Self.customEndpoint, reachable: true, chainId: 10),
        Probe(url: second, reachable: true, chainId: 8453),
      ])
  }

  @Test
  func eachEndpointIsProbedOnlyOnce() async throws {
    let (resolver, recorder) = makeResolver(
      customEndpoints: [Self.customEndpoint], handler: chainIdHandler)

    _ = await resolver.client(for: .optimism)
    #expect(recorder.count(for: Self.customEndpoint) == 1)

    // A second `probeAll()` and a second `client(for:)` call must not
    // re-issue `eth_chainId` for an already-probed endpoint.
    _ = await resolver.probeAll()
    _ = await resolver.client(for: .optimism)
    #expect(recorder.count(for: Self.customEndpoint) == 1)
  }

  @Test
  func concurrentCallsCoalesceIntoOneProbePerEndpoint() async throws {
    let (resolver, recorder) = makeResolver(
      customEndpoints: [Self.customEndpoint], handler: chainIdHandler)

    async let first = resolver.client(for: .optimism)
    async let second = resolver.probeAll()
    async let third = resolver.client(for: .optimism)
    _ = await (first, second, third)

    #expect(recorder.count(for: Self.customEndpoint) == 1)
  }

  @Test
  func multipleMatchingCustomEndpointsPreferFirstInUserOrder() async throws {
    let second = "https://second.custom.test"
    let (resolver, recorder) = makeResolver(
      customEndpoints: [Self.customEndpoint, second]
    ) { request in
      switch request.url?.absoluteString {
      case Self.customEndpoint, second:
        return (
          AlchemyTestSupport.okResponse(for: request),
          Data(#"{"jsonrpc":"2.0","id":1,"result":"0xa"}"#.utf8)
        )
      default:
        return (AlchemyTestSupport.response(for: request, statusCode: 404), Data())
      }
    }
    let resolved = await resolver.client(for: .optimism)
    guard case .direct(let client) = resolved else {
      Issue.record("Expected .direct, got \(resolved)")
      return
    }
    // Resolution stops at the first matching endpoint without even
    // probing the second.
    #expect(recorder.count(for: Self.customEndpoint) == 1)
    #expect(recorder.count(for: second) == 0)
    // Confirm the returned client actually targets the first endpoint (not
    // merely that resolution stopped there) by issuing a request through
    // it and checking which endpoint received it.
    _ = try await client.chainId()
    #expect(recorder.count(for: Self.customEndpoint) == 2)
    #expect(recorder.count(for: second) == 0)
  }

  @Test
  func alchemyKeyPresenceIsEvaluatedAtResolutionTimeNotConstructionTime() async throws {
    let keyPresent = MutableFlag(true)
    let (resolver, _) = makeResolver(
      customEndpoints: [],
      alchemyKeyPresent: { keyPresent.value },
      handler: { request in
        (AlchemyTestSupport.response(for: request, statusCode: 404), Data())
      })

    let firstResolved = await resolver.client(for: .ethereum)
    guard case .alchemy = firstResolved else {
      Issue.record("Expected .alchemy, got \(firstResolved)")
      return
    }

    keyPresent.value = false
    let secondResolved = await resolver.client(for: .ethereum)
    guard case .direct = secondResolved else {
      Issue.record("Expected .direct (default publicnode), got \(secondResolved)")
      return
    }
  }
}

private typealias Probe = RPCEndpointResolver.Probe

/// Thread-safe recorder for the URLProtocol handler closure (which must be
/// `@Sendable`), tracking every request URL seen so tests can assert both a
/// total call count and a per-endpoint call count (to prove caching/
/// coalescing actually suppressed a second network round-trip).
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

  var total: Int {
    lock.lock()
    defer { lock.unlock() }
    return urls.count
  }
}

/// Thread-safe mutable flag for scripting `alchemyKeyPresent` differently
/// across two `client(for:)` calls in the same test — proves the closure is
/// invoked at resolution time rather than captured once at construction.
private final class MutableFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Bool

  init(_ value: Bool) {
    self.storedValue = value
  }

  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedValue = newValue
    }
  }
}

/// Dedicated `URLProtocol` stub for the `RPCEndpointResolver` suite, with its
/// own static handler state so it cannot race other suites' stubs when Swift
/// Testing runs suites in parallel. `nonisolated(unsafe)` on the static is
/// safe because the enclosing `@Suite` is marked `.serialized`, so tests
/// within it never run concurrently: the handler is assigned in
/// `makeResolver` before any stub invocation, and no two tests in this suite
/// touch the static concurrently.
private final class RPCEndpointResolverURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = RPCEndpointResolverURLProtocolStub.requestHandler else {
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
