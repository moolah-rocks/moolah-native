// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient", .serialized)
struct LiveBlockscoutClientTests {
  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveBlockscoutClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BlockscoutURLProtocolStub.self]
    let session = URLSession(configuration: config)
    BlockscoutURLProtocolStub.requestHandler = handler
    BlockscoutURLProtocolStub.lastRequest = nil
    return LiveBlockscoutClient(
      session: session, rateLimiter: RateLimiter(permitsPerSecond: 1_000))
  }

  @Test
  func nativeTransactionsHitsCorrectHostAndPath() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("blockscout-tx-value")
    let client = makeClient { req in
      BlockscoutURLProtocolStub.captureRequest(req)
      return (AlchemyTestSupport.okResponse(for: req), fixture)
    }
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xABC", fromBlock: 0)
    let url = try #require(BlockscoutURLProtocolStub.lastRequest?.url)
    #expect(url.host == "eth.blockscout.com")
    #expect(url.path == "/api/v2/addresses/0xABC/transactions")
    #expect(txs.count == 1)
  }

  @Test
  func internalTransactionsHitsCorrectPath() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let client = makeClient { req in
      BlockscoutURLProtocolStub.captureRequest(req)
      return (AlchemyTestSupport.okResponse(for: req), fixture)
    }
    _ = try await client.internalTransactions(
      chain: .optimism, walletAddress: "0xABC", fromBlock: 0)
    let url = try #require(BlockscoutURLProtocolStub.lastRequest?.url)
    #expect(url.host == "explorer.optimism.io")
    #expect(url.path == "/api/v2/addresses/0xABC/internal-transactions")
  }

  @Test
  func paginatesUntilCursorAbsentAndStopsBelowFromBlock() async throws {
    // Page 1: one item at block 100, cursor → block 50.
    // Page 2: one item at block 40 (below fromBlock 45) → stop, no page 3.
    let page1 = Data(
      #"""
      {"items":[{"hash":"0xaa","block_number":100,"timestamp":"2024-01-01T00:00:00.000000Z","from":{"hash":"0xabc"},"to":{"hash":"0xdef"},"value":"10","status":"ok","result":"success"}],"next_page_params":{"block_number":50,"index":1,"items_count":50}}
      """#.utf8)
    let page2 = Data(
      #"""
      {"items":[{"hash":"0xbb","block_number":40,"timestamp":"2024-01-01T00:00:00.000000Z","from":{"hash":"0xabc"},"to":{"hash":"0xdef"},"value":"10","status":"ok","result":"success"}],"next_page_params":{"block_number":10,"index":1,"items_count":50}}
      """#.utf8)
    let calls = TestCallRecorder()
    let client = makeClient { req in
      calls.record(request: req)
      let hasCursor = req.url?.query?.contains("block_number=50") ?? false
      return (AlchemyTestSupport.okResponse(for: req), hasCursor ? page2 : page1)
    }
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 45)
    #expect(txs.map(\.hash) == ["0xaa", "0xbb"])
    #expect(calls.captured.count == 2)  // stopped: page2's last block 40 < fromBlock 45
  }

  @Test
  func mapsHTTP429ToRateLimited() async throws {
    let client = makeClient { req in
      (AlchemyTestSupport.response(for: req, statusCode: 429), Data())
    }
    do {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let error as WalletSyncError {
      guard case .rateLimited = error.kind else {
        Issue.record("Expected WalletSyncError.rateLimited, got \(error)")
        return
      }
      // expected
    } catch {
      Issue.record("Expected WalletSyncError.rateLimited, got \(error)")
    }
  }

  @Test
  func malformedJSONThrowsProviderMalformedResponse() async throws {
    let client = makeClient { req in
      (AlchemyTestSupport.okResponse(for: req), Data("not json".utf8))
    }
    do {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("Expected WalletSyncError.providerMalformedResponse")
    } catch let error as WalletSyncError {
      guard case .providerMalformedResponse(let stage) = error.kind else {
        Issue.record("Expected .providerMalformedResponse, got \(error.kind)")
        return
      }
      #expect(stage == "blockscout.transactions")
      #expect(error.provider == .blockExplorer)
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }
}

/// Dedicated URLProtocol stub for the Blockscout live-client tests, with its
/// own static handler state so it cannot race `AlchemyURLProtocolStub` when
/// Swift Testing runs suites in parallel. `nonisolated(unsafe)` on the statics
/// is safe because the enclosing `@Suite` is marked `.serialized` — Swift
/// Testing runs tests within a suite concurrently by default, but here the
/// handler is assigned in `makeClient` before any stub invocation, and no two
/// tests in this suite touch the statics concurrently.
class BlockscoutURLProtocolStub: URLProtocol {
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
    guard let handler = BlockscoutURLProtocolStub.requestHandler else {
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
