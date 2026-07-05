// MoolahTests/Shared/CryptoImport/LiveJSONRPCClientTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `LiveJSONRPCClient`'s transport: hex-quantity decoding for
/// `eth_chainId`/`eth_blockNumber`, the in-place `Retry-After` honouring
/// (mirroring `LiveBlockscoutClient`'s public-endpoint policy), and the
/// JSON-RPC-level `{"error": ...}` envelope (a 200 with an error body, not
/// a retryable HTTP status).
@Suite("LiveJSONRPCClient", .serialized)
struct LiveJSONRPCClientTests {
  private static let endpoint = URL(string: "https://rpc.example.test")!

  private func makeClient(
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveJSONRPCClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JSONRPCURLProtocolStub.self]
    let session = URLSession(configuration: config)
    JSONRPCURLProtocolStub.requestHandler = handler
    JSONRPCURLProtocolStub.lastRequest = nil
    return LiveJSONRPCClient(
      endpoint: Self.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: sleeper)
  }

  @Test
  func chainIdDecodesHexQuantity() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#.utf8)
      )
    }
    let chainId = try await client.chainId()
    #expect(chainId == 1)
  }

  @Test
  func blockNumberDecodesHexQuantity() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x10"}"#.utf8)
      )
    }
    let blockNumber = try await client.blockNumber()
    #expect(blockNumber == 16)
  }

  @Test
  func requestHitsInjectedEndpointWithPOSTBody() async throws {
    let client = makeClient { request in
      JSONRPCURLProtocolStub.captureRequest(request)
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#.utf8)
      )
    }
    _ = try await client.chainId()
    let request = try #require(JSONRPCURLProtocolStub.lastRequest)
    #expect(request.url == Self.endpoint)
    #expect(request.httpMethod == "POST")
  }

  @Test
  func transientRateLimitWithShortRetryAfterIsRetriedInPlaceThenSucceeds() async throws {
    let counter = CallCounter()
    let client = makeClient { request in
      if counter.next() == 1 {
        return (
          AlchemyTestSupport.response(
            for: request, statusCode: 429, headerFields: ["Retry-After": "1"]),
          Data()
        )
      }
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#.utf8)
      )
    }
    let chainId = try await client.chainId()
    #expect(chainId == 1)
    // First attempt 429s (Retry-After honoured in place), second succeeds.
    #expect(counter.total == 2)
  }

  @Test
  func providerErrorBodyThrowsProviderMalformedResponse() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"boom"}}"#.utf8)
      )
    }
    do {
      _ = try await client.chainId()
      Issue.record("Expected WalletSyncError.providerMalformedResponse")
    } catch let error as WalletSyncError {
      guard case .providerMalformedResponse(let stage) = error.kind else {
        Issue.record("Expected .providerMalformedResponse, got \(error.kind)")
        return
      }
      #expect(stage == "chainId")
    }
  }

  @Test
  func chainIdRejectsHexQuantityAboveIntMaxInsteadOfTrapping() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0xffffffffffffffff"}"#.utf8)
      )
    }
    await #expect(throws: WalletSyncError.providerMalformedResponse(stage: "chainId")) {
      _ = try await client.chainId()
    }
  }
}

/// Thread-safe call counter for the URLProtocol handler closure, which must
/// be `@Sendable`. Mirrors `LiveAlchemyClientRetryTests`'s private helper —
/// duplicated rather than shared because that one is file-private.
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }

  var total: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Dedicated `URLProtocol` stub for the `LiveJSONRPCClient` suite, with its
/// own static handler state so it cannot race `AlchemyURLProtocolStub` /
/// `BlockscoutURLProtocolStub` when Swift Testing runs suites in parallel.
/// `nonisolated(unsafe)` on the statics is safe because the enclosing
/// `@Suite` is marked `.serialized`, so tests within it never run
/// concurrently: the handler is assigned in `makeClient` before any stub
/// invocation, and no two tests in this suite touch the statics
/// concurrently.
class JSONRPCURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?

  /// Records the request that was just received. Tests opt-in by calling
  /// this from their handler closure.
  static func captureRequest(_ request: URLRequest) {
    lastRequest = request
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = JSONRPCURLProtocolStub.requestHandler else {
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
