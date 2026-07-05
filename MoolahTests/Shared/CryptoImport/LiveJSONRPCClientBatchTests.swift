// MoolahTests/Shared/CryptoImport/LiveJSONRPCClientBatchTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `LiveJSONRPCClient`'s batched `eth_getBlockByNumber` timestamp
/// lookup and single `eth_call`. `blockTimestamps` is the only batch caller
/// so far — these tests pin the "one HTTP request per batch, id-correlated
/// regardless of response order" contract `JSONRPCEnvelope.correlate`
/// provides.
@Suite("LiveJSONRPCClientBatch", .serialized)
struct LiveJSONRPCClientBatchTests {
  private static let endpoint = URL(string: "https://rpc.example.test")!

  private func makeClient(
    sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveJSONRPCClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JSONRPCBatchURLProtocolStub.self]
    let session = URLSession(configuration: config)
    JSONRPCBatchURLProtocolStub.requestHandler = handler
    JSONRPCBatchURLProtocolStub.lastRequest = nil
    JSONRPCBatchURLProtocolStub.requestCount = 0
    return LiveJSONRPCClient(
      endpoint: Self.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: sleeper)
  }

  // MARK: - blockTimestamps

  @Test
  func blockTimestampsIssuesOneBatchRequestAndMapsTimestamps() async throws {
    let client = makeClient { request in
      JSONRPCBatchURLProtocolStub.captureRequest(request)
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(
          """
          [
            {"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x60"}},
            {"jsonrpc":"2.0","id":2,"result":{"timestamp":"0x61"}}
          ]
          """.utf8)
      )
    }
    let timestamps = try await client.blockTimestamps([16, 17])
    #expect(JSONRPCBatchURLProtocolStub.requestCount == 1)
    #expect(timestamps[16] == Date(timeIntervalSince1970: 0x60))
    #expect(timestamps[17] == Date(timeIntervalSince1970: 0x61))
  }

  @Test
  func blockTimestampsReCorrelatesReorderedResponseIds() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(
          """
          [
            {"jsonrpc":"2.0","id":2,"result":{"timestamp":"0x61"}},
            {"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x60"}}
          ]
          """.utf8)
      )
    }
    let timestamps = try await client.blockTimestamps([16, 17])
    #expect(timestamps[16] == Date(timeIntervalSince1970: 0x60))
    #expect(timestamps[17] == Date(timeIntervalSince1970: 0x61))
  }

  @Test
  func blockTimestampsRequestBodyEncodesBatchArrayWithIncludeTransactionsFalse() async throws {
    let client = makeClient { request in
      JSONRPCBatchURLProtocolStub.captureRequest(request)
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(
          """
          [{"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x60"}}]
          """.utf8)
      )
    }
    _ = try await client.blockTimestamps([16])
    let body = try #require(JSONRPCBatchURLProtocolStub.lastRequestBody)
    let array = try #require(body as? [[String: Any]])
    #expect(array.count == 1)
    #expect(array[0]["method"] as? String == "eth_getBlockByNumber")
    let params = try #require(array[0]["params"] as? [Any])
    #expect(params.count == 2)
    #expect(params[0] as? String == "0x10")
    #expect(params[1] as? Bool == false)
  }

  @Test
  func blockTimestampsWithMismatchedBatchIdsThrowsProviderMalformedResponse() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(
          """
          [
            {"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x60"}},
            {"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x60"}}
          ]
          """.utf8)
      )
    }
    do {
      _ = try await client.blockTimestamps([16, 17])
      Issue.record("Expected WalletSyncError.providerMalformedResponse")
    } catch let error as WalletSyncError {
      guard case .providerMalformedResponse(let stage) = error.kind else {
        Issue.record("Expected .providerMalformedResponse, got \(error.kind)")
        return
      }
      #expect(stage == "blockTimestamps")
    }
  }

  @Test
  func blockTimestampsWithEmptyInputReturnsEmptyWithoutARequest() async throws {
    let client = makeClient { _ in
      Issue.record("Expected no HTTP request for empty input")
      throw URLError(.unknown)
    }
    let timestamps = try await client.blockTimestamps([])
    #expect(timestamps.isEmpty)
  }

  // MARK: - call(to:data:)

  @Test
  func callReturnsResultHexString() async throws {
    let client = makeClient { request in
      JSONRPCBatchURLProtocolStub.captureRequest(request)
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0xdeadbeef"}"#.utf8)
      )
    }
    let result = try await client.call(
      to: "0x1234567890123456789012345678901234567890", data: "0xa9059cbb")
    #expect(result == "0xdeadbeef")
    let body = try #require(JSONRPCBatchURLProtocolStub.lastRequestBody)
    let object = try #require(body as? [String: Any])
    #expect(object["method"] as? String == "eth_call")
    let params = try #require(object["params"] as? [Any])
    #expect(params.count == 2)
    let callObject = try #require(params[0] as? [String: Any])
    #expect(callObject["to"] as? String == "0x1234567890123456789012345678901234567890")
    #expect(callObject["data"] as? String == "0xa9059cbb")
    #expect(params[1] as? String == "latest")
  }
}

/// Dedicated `URLProtocol` stub for the batch-oriented `LiveJSONRPCClient`
/// tests, with its own static state so it cannot race the non-batch
/// `JSONRPCURLProtocolStub` (or any other suite's stub) when Swift Testing
/// runs suites in parallel. `nonisolated(unsafe)` is safe because the
/// enclosing `@Suite` is `.serialized`.
final class JSONRPCBatchURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?
  nonisolated(unsafe) static var lastRequestBody: Any?
  nonisolated(unsafe) static var requestCount = 0

  /// Records the request that was just received, including its decoded
  /// JSON body (streamed or in-memory). `requestCount` is tracked
  /// unconditionally in `startLoading` below, so tests that only care about
  /// the request tally don't need to opt in here.
  static func captureRequest(_ request: URLRequest) {
    lastRequest = request
    if let stream = request.httpBodyStream {
      lastRequestBody = decodeBodyStream(stream)
    } else if let body = request.httpBody {
      lastRequestBody = try? JSONSerialization.jsonObject(
        with: body, options: [.fragmentsAllowed])
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    JSONRPCBatchURLProtocolStub.requestCount += 1
    guard let handler = JSONRPCBatchURLProtocolStub.requestHandler else {
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

  private static func decodeBodyStream(_ stream: InputStream) -> Any? {
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }
}
