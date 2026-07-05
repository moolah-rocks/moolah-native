// MoolahTests/Shared/CryptoImport/TokenMetadataResolverTestSupport.swift
import Foundation

@testable import Moolah

/// Shared fixtures and stub plumbing for `TokenMetadataResolver`'s test
/// suites — split across `TokenMetadataResolverTests` (happy path, cache
/// coalescing, revert/malformed) and
/// `TokenMetadataResolverHostileTests` (ABI-overflow and
/// transient-failure negative-caching hardening) to keep each suite under
/// the file-length/type-body-length thresholds — so both build a resolver
/// against the same isolated `URLProtocol` stub without duplicating the
/// ABI-encoding helpers.
enum TokenMetadataResolverTestSupport {
  static let endpoint = URL(string: "https://rpc.example.test")!
  static let contract = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  static let decimalsSelector = "0x313ce567"
  static let symbolSelector = "0x95d89b41"

  static func makeResolver(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> TokenMetadataResolver {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TokenMetadataResolverURLProtocolStub.self]
    let session = URLSession(configuration: config)
    TokenMetadataResolverURLProtocolStub.requestHandler = handler
    TokenMetadataResolverURLProtocolStub.requestCount = 0
    let rpc = LiveJSONRPCClient(
      endpoint: endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: { _ in })
    return TokenMetadataResolver(rpc: rpc)
  }

  /// Extracts the `eth_call` selector (the `data` field of the positional
  /// `[{to, data}, "latest"]` params) from a captured request body, so the
  /// stub handler can answer `decimals()` and `symbol()` differently.
  static func selector(from request: URLRequest) -> String? {
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
  static func abiEncodedString(_ value: String) -> String {
    let bytes = Array(value.utf8)
    var dataHex = bytes.map { String(format: "%02x", $0) }.joined()
    let remainder = dataHex.count % 64
    if remainder != 0 {
      dataHex += String(repeating: "0", count: 64 - remainder)
    }
    return "0x" + word(32) + word(bytes.count) + dataHex
  }

  /// Encodes `value` as a single zero-padded 64-hex-char ABI word.
  static func word(_ value: Int) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: 64 - raw.count) + raw
  }

  static func okResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
    (AlchemyTestSupport.okResponse(for: request), Data(body.utf8))
  }
}

/// Dedicated `URLProtocol` stub for the `TokenMetadataResolver` suites, with
/// its own static handler state so it cannot race any other suite's stub
/// (`JSONRPCURLProtocolStub`, `JSONRPCBatchURLProtocolStub`,
/// `AlchemyURLProtocolStub`, ...) when Swift Testing runs suites in
/// parallel. `nonisolated(unsafe)` on the statics is safe because both
/// `TokenMetadataResolverTests` and `TokenMetadataResolverHostileTests`
/// are `@Suite(.serialized)`, so no two tests using this stub touch it
/// concurrently.
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
