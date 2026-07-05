// MoolahTests/Shared/CryptoImport/TokenMetadataResolverTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `TokenMetadataResolver`'s ABI decoding (`decimals()`/`symbol()`
/// via `eth_call`) and its per-contract cache for the well-behaved paths:
/// happy-path resolution, cache/in-flight coalescing, and revert/malformed
/// responses. Hostile-contract ABI-overflow decoding and
/// transient-failure negative-caching coverage lives in
/// `TokenMetadataResolverHostileTests`, split out to keep each
/// suite under the file-length/type-body-length thresholds; both share
/// pure fixtures via `TokenMetadataResolverTestSupport`, but each suite
/// owns its own `URLProtocol` stub (below) and `makeResolver` helper so
/// no mutable state is shared between the two suites when Swift Testing
/// runs them in parallel.
@Suite("TokenMetadataResolver", .serialized)
struct TokenMetadataResolverTests {
  private typealias Support = TokenMetadataResolverTestSupport

  private static func makeResolver(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> TokenMetadataResolver {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenMetadataResolverURLProtocolStub.self]
    let session = URLSession(configuration: config)
    TokenMetadataResolverURLProtocolStub.requestHandler = handler
    TokenMetadataResolverURLProtocolStub.requestCount = 0
    let rpc = LiveJSONRPCClient(
      endpoint: Support.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: { _ in })
    return TokenMetadataResolver(rpc: rpc)
  }

  // MARK: - Happy path

  @Test
  func resolvesDecimalsAndSymbol() async throws {
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
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Support.abiEncodedString("USDC"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 6, symbol: "USDC"))
  }

  // MARK: - Cache coalescing

  @Test
  func secondLookupForSameContractIssuesNoNewCall() async throws {
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x12"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Support.abiEncodedString("WETH"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let first = await resolver.metadata(for: Support.contract)
    #expect(first == .init(decimals: 18, symbol: "WETH"))
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount
    #expect(callsAfterFirstLookup == 2)  // one for decimals, one for symbol

    let second = await resolver.metadata(for: Support.contract)
    #expect(second == .init(decimals: 18, symbol: "WETH"))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func lookupIsCaseInsensitiveOnContractAddress() async throws {
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
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Support.abiEncodedString("USDC"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    _ = await resolver.metadata(for: Support.contract.lowercased())
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount
    let second = await resolver.metadata(for: Support.contract.uppercased())
    #expect(second == .init(decimals: 6, symbol: "USDC"))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  // MARK: - Revert / malformed

  @Test
  func decimalsRevertResolvesToNil() async throws {
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("symbol() should not be called when decimals() fails")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == nil)
  }

  @Test
  func decimalsRevertIsCachedAsNilWithoutReissuingTheCall() async throws {
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request), selector == Support.decimalsSelector
      else {
        Issue.record("Only decimals() should ever be called for a broken contract")
        throw URLError(.unknown)
      }
      return Support.okResponse(
        for: request,
        body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#)
    }
    let first = await resolver.metadata(for: Support.contract)
    #expect(first == nil)
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount

    let second = await resolver.metadata(for: Support.contract)
    #expect(second == nil)
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func emptyDecimalsResultResolvesToNil() async throws {
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request), selector == Support.decimalsSelector
      else {
        Issue.record("symbol() should not be called when decimals() is empty")
        throw URLError(.unknown)
      }
      return Support.okResponse(for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x"}"#)
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == nil)
  }

  @Test
  func symbolRevertYieldsNilSymbolButKeepsDecimals() async throws {
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x8"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 8, symbol: nil))
  }

  @Test
  func symbolRevertIsCachedWithoutReissuingTheCall() async throws {
    // A symbol() revert is a PERMANENT failure (unlike a transient
    // rate-limit/network error) — it resolves with the known-good decimals
    // and a nil symbol, and that result is cached: a second lookup for the
    // same contract must not re-issue either `eth_call`.
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x8"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let first = await resolver.metadata(for: Support.contract)
    #expect(first == .init(decimals: 8, symbol: nil))
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount

    let second = await resolver.metadata(for: Support.contract)
    #expect(second == .init(decimals: 8, symbol: nil))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func legacyBytes32SymbolDecodesAsRightPaddedASCII() async throws {
    // MKR-style legacy encoding: symbol() returns a fixed bytes32, not the
    // standard dynamic string — just the right-zero-padded ASCII bytes with
    // no offset/length prefix.
    let bytes32Symbol =
      "0x4d4b520000000000000000000000000000000000000000000000000000000000"
    let resolver = Self.makeResolver { request in
      guard let selector = Support.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Support.decimalsSelector:
        return Support.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x12"}"#)
      case Support.symbolSelector:
        return Support.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"result":"\#(bytes32Symbol)"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Support.contract)
    #expect(metadata == .init(decimals: 18, symbol: "MKR"))
  }
}

/// Dedicated `URLProtocol` stub for `TokenMetadataResolverTests` only, with
/// its own static handler state so it cannot race
/// `TokenMetadataResolverHostileTests`' stub when Swift Testing runs the two
/// suites in parallel. `nonisolated(unsafe)` on the statics is safe because
/// this suite is `@Suite(.serialized)`, so no two tests here touch it
/// concurrently.
private final class TokenMetadataResolverURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var requestCount = 0

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    TokenMetadataResolverURLProtocolStub.requestCount += 1
    guard let handler = TokenMetadataResolverURLProtocolStub.requestHandler else {
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
