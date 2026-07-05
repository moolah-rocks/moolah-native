// MoolahTests/Shared/CryptoImport/TokenMetadataResolverHostileTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `TokenMetadataResolver`'s hardening against a hostile/malicious
/// contract: ABI-decode overflow protection in the `symbol()` dynamic-string
/// decoder, bounding `decimals()` to its declared `uint8` range, and
/// negative-caching only *permanent* failures (a transient rate-limit/
/// network/cancellation failure must not be remembered as "this contract
/// doesn't work"). Well-behaved-path coverage (happy path, cache
/// coalescing, revert/malformed) lives in `TokenMetadataResolverTests`;
/// both share pure fixtures via `TokenMetadataResolverTestSupport`, but
/// each suite owns its own `URLProtocol` stub (below) and `makeResolver`
/// helper so no mutable state is shared between the two suites when Swift
/// Testing runs them in parallel.
@Suite("TokenMetadataResolver — hostile contracts", .serialized)
struct TokenMetadataResolverHostileTests {
  private typealias Support = TokenMetadataResolverTestSupport

  private static func makeResolver(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> TokenMetadataResolver {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenMetadataHostileURLProtocolStub.self]
    let session = URLSession(configuration: config)
    TokenMetadataHostileURLProtocolStub.requestHandler = handler
    TokenMetadataHostileURLProtocolStub.requestCount = 0
    let rpc = LiveJSONRPCClient(
      endpoint: Support.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: { _ in })
    return TokenMetadataResolver(rpc: rpc)
  }

  // MARK: - Hostile-contract ABI decoding

  @Test
  func symbolHugeOffsetWordDecodesToNilWithoutCrashing() async throws {
    // A dynamic-string response whose offset word parses successfully as
    // an `Int` (it's `Int.max`, zero-padded to one ABI word) but is far
    // larger than the response itself. Before the overflow fix,
    // `offsetBytes * 2` trapped (SIGTRAP) here instead of returning nil.
    let hugeOffsetResult = "0x" + Support.word(Int.max) + Support.word(0)
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x6"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"result":"\#(hugeOffsetResult)"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 6, symbol: nil))
  }

  @Test
  func decimalsAboveUInt8RangeResolvesToNil() async throws {
    // decimals() declares `uint8` (0...255) but a hostile contract can
    // return anything that still parses as an `Int` — 5_000_000_000 here.
    // Downstream `pow(10, decimals)` amount scaling can't handle that
    // safely, so it must be rejected rather than trusted.
    let outOfRangeDecimals = String(5_000_000_000, radix: 16)
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request), selector == Support.decimalsSelector
      else {
        Issue.record("symbol() should not be called when decimals() is out of range")
        throw URLError(.unknown)
      }
      return Support.okResponse(
        for: request,
        body: #"{"jsonrpc":"2.0","id":1,"result":"0x\#(outOfRangeDecimals)"}"#)
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == nil)
  }

  // MARK: - Transient failures are not negative-cached

  @Test
  func transientDecimalsRateLimitFailureIsNotCachedAndRetriesOnNextLookup() async throws {
    // Every attempt 429s with a short `Retry-After` (honoured in place by
    // `LiveJSONRPCClient`'s retry policy), so the retry budget (4 attempts)
    // is exhausted and `rpc.call` ultimately throws
    // `WalletSyncError.rateLimited` — a transient failure that must NOT be
    // negative-cached, unlike a permanent revert/malformed response.
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request), selector == Support.decimalsSelector
      else {
        Issue.record("symbol() should not be called when decimals() fails")
        throw URLError(.unknown)
      }
      return (
        AlchemyTestSupport.response(
          for: request, statusCode: 429, headerFields: ["Retry-After": "1"]),
        Data()
      )
    }
    let first = await resolver.metadata(for: Support.contract)
    #expect(first == nil)
    let callsAfterFirstLookup = TokenMetadataHostileURLProtocolStub.requestCount
    #expect(callsAfterFirstLookup == 4)  // the retry policy's full attempt budget

    let second = await resolver.metadata(for: Support.contract)
    #expect(second == nil)
    // Not negative-cached: the second lookup re-issues its own full retry
    // budget of `eth_call`s rather than returning an already-cached `nil`.
    #expect(TokenMetadataHostileURLProtocolStub.requestCount == callsAfterFirstLookup * 2)
  }
}

/// Dedicated `URLProtocol` stub for `TokenMetadataResolverHostileTests`
/// only, with its own static handler state so it cannot race
/// `TokenMetadataResolverTests`' stub when Swift Testing runs the two
/// suites in parallel. `nonisolated(unsafe)` on the statics is safe because
/// this suite is `@Suite(.serialized)`, so no two tests here touch it
/// concurrently.
private final class TokenMetadataHostileURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var requestCount = 0

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    TokenMetadataHostileURLProtocolStub.requestCount += 1
    guard let handler = TokenMetadataHostileURLProtocolStub.requestHandler else {
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
