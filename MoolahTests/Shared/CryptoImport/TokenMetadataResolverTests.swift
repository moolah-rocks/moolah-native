// MoolahTests/Shared/CryptoImport/TokenMetadataResolverTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `TokenMetadataResolver`'s ABI decoding (`decimals()`/`symbol()`
/// via `eth_call`) and its per-contract cache: a resolved contract must not
/// re-issue `eth_call`s on a later lookup, and a contract whose
/// `decimals()` reverts must resolve to `nil`.
@Suite("TokenMetadataResolver", .serialized)
struct TokenMetadataResolverTests {
  private static let endpoint = URL(string: "https://rpc.example.test")!
  private static let contract = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  private static let decimalsSelector = "0x313ce567"
  private static let symbolSelector = "0x95d89b41"

  private func makeResolver(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> TokenMetadataResolver {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenMetadataResolverURLProtocolStub.self]
    let session = URLSession(configuration: config)
    TokenMetadataResolverURLProtocolStub.requestHandler = handler
    TokenMetadataResolverURLProtocolStub.requestCount = 0
    let rpc = LiveJSONRPCClient(
      endpoint: Self.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: { _ in })
    return TokenMetadataResolver(rpc: rpc)
  }

  /// Extracts the `eth_call` selector (the `data` field of the positional
  /// `[{to, data}, "latest"]` params) from a captured request body, so the
  /// stub handler can answer `decimals()` and `symbol()` differently.
  private static func selector(from request: URLRequest) -> String? {
    let data: Data?
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var collected = Data()
      let bufferSize = 1_024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 { break }
        collected.append(buffer, count: read)
      }
      data = collected
    } else {
      data = request.httpBody
    }
    guard let data,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let params = object["params"] as? [Any],
      let callObject = params.first as? [String: Any]
    else { return nil }
    return callObject["data"] as? String
  }

  /// Encodes `value` as an ABI dynamic `string` result: an offset word
  /// (always `0x20`, one word), a length word, then the UTF-8 bytes
  /// zero-padded to a 32-byte boundary — the shape a standard ERC-20
  /// `symbol()` call returns.
  private static func abiEncodedString(_ value: String) -> String {
    let bytes = Array(value.utf8)
    var dataHex = bytes.map { String(format: "%02x", $0) }.joined()
    let remainder = dataHex.count % 64
    if remainder != 0 {
      dataHex += String(repeating: "0", count: 64 - remainder)
    }
    return "0x" + word(32) + word(bytes.count) + dataHex
  }

  private static func word(_ value: Int) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: 64 - raw.count) + raw
  }

  private static func okResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
    (AlchemyTestSupport.okResponse(for: request), Data(body.utf8))
  }

  // MARK: - Happy path

  @Test
  func resolvesDecimalsAndSymbol() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Self.decimalsSelector:
        return Self.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x6"}"#)
      case Self.symbolSelector:
        return Self.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Self.abiEncodedString("USDC"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Self.contract)
    #expect(metadata == .init(decimals: 6, symbol: "USDC"))
  }

  // MARK: - Cache coalescing

  @Test
  func secondLookupForSameContractIssuesNoNewCall() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Self.decimalsSelector:
        return Self.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x12"}"#)
      case Self.symbolSelector:
        return Self.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Self.abiEncodedString("WETH"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let first = await resolver.metadata(for: Self.contract)
    #expect(first == .init(decimals: 18, symbol: "WETH"))
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount
    #expect(callsAfterFirstLookup == 2)  // one for decimals, one for symbol

    let second = await resolver.metadata(for: Self.contract)
    #expect(second == .init(decimals: 18, symbol: "WETH"))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func lookupIsCaseInsensitiveOnContractAddress() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Self.decimalsSelector:
        return Self.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x6"}"#)
      case Self.symbolSelector:
        return Self.okResponse(
          for: request,
          body:
            #"{"jsonrpc":"2.0","id":1,"result":"\#(Self.abiEncodedString("USDC"))"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    _ = await resolver.metadata(for: Self.contract.lowercased())
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount
    let second = await resolver.metadata(for: Self.contract.uppercased())
    #expect(second == .init(decimals: 6, symbol: "USDC"))
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  // MARK: - Revert / malformed

  @Test
  func decimalsRevertResolvesToNil() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Self.decimalsSelector:
        return Self.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("symbol() should not be called when decimals() fails")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Self.contract)
    #expect(metadata == nil)
  }

  @Test
  func decimalsRevertIsCachedAsNilWithoutReissuingTheCall() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request), selector == Self.decimalsSelector else {
        Issue.record("Only decimals() should ever be called for a broken contract")
        throw URLError(.unknown)
      }
      return Self.okResponse(
        for: request,
        body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#)
    }
    let first = await resolver.metadata(for: Self.contract)
    #expect(first == nil)
    let callsAfterFirstLookup = TokenMetadataResolverURLProtocolStub.requestCount

    let second = await resolver.metadata(for: Self.contract)
    #expect(second == nil)
    #expect(TokenMetadataResolverURLProtocolStub.requestCount == callsAfterFirstLookup)
  }

  @Test
  func emptyDecimalsResultResolvesToNil() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request), selector == Self.decimalsSelector else {
        Issue.record("symbol() should not be called when decimals() is empty")
        throw URLError(.unknown)
      }
      return Self.okResponse(for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x"}"#)
    }
    let metadata = await resolver.metadata(for: Self.contract)
    #expect(metadata == nil)
  }

  @Test
  func symbolRevertYieldsNilSymbolButKeepsDecimals() async throws {
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Self.decimalsSelector:
        return Self.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x8"}"#)
      case Self.symbolSelector:
        return Self.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"execution reverted"}}"#
        )
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Self.contract)
    #expect(metadata == .init(decimals: 8, symbol: nil))
  }

  @Test
  func legacyBytes32SymbolDecodesAsRightPaddedASCII() async throws {
    // MKR-style legacy encoding: symbol() returns a fixed bytes32, not the
    // standard dynamic string — just the right-zero-padded ASCII bytes with
    // no offset/length prefix.
    let bytes32Symbol =
      "0x4d4b520000000000000000000000000000000000000000000000000000000000"
    let resolver = makeResolver { request in
      guard let selector = Self.selector(from: request) else {
        Issue.record("Missing eth_call selector in request body")
        throw URLError(.unknown)
      }
      switch selector {
      case Self.decimalsSelector:
        return Self.okResponse(
          for: request, body: #"{"jsonrpc":"2.0","id":1,"result":"0x12"}"#)
      case Self.symbolSelector:
        return Self.okResponse(
          for: request,
          body: #"{"jsonrpc":"2.0","id":1,"result":"\#(bytes32Symbol)"}"#)
      default:
        Issue.record("Unexpected selector \(selector)")
        throw URLError(.unknown)
      }
    }
    let metadata = await resolver.metadata(for: Self.contract)
    #expect(metadata == .init(decimals: 18, symbol: "MKR"))
  }
}

/// Dedicated `URLProtocol` stub for the `TokenMetadataResolver` suite, with
/// its own static handler state so it cannot race any other suite's stub
/// (`JSONRPCURLProtocolStub`, `JSONRPCBatchURLProtocolStub`,
/// `AlchemyURLProtocolStub`, ...) when Swift Testing runs suites in
/// parallel. `nonisolated(unsafe)` on the statics is safe because the
/// enclosing `@Suite` is `.serialized`, so no two tests in this suite touch
/// them concurrently.
final class TokenMetadataResolverURLProtocolStub: URLProtocol {
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
