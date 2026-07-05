// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient provider attribution")
struct LiveBlockscoutClientAttributionTests {
  private func makeFailingClient() -> LiveBlockscoutClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BlockscoutAttributionURLProtocolStub.self]
    let session = URLSession(configuration: config)
    // Throw a URLError from the stub to force a WalletSyncError.network throw.
    BlockscoutAttributionURLProtocolStub.requestHandler = { _ in
      throw URLError(.cannotConnectToHost)
    }
    BlockscoutAttributionURLProtocolStub.lastRequest = nil
    return LiveBlockscoutClient(
      session: session, rateLimiter: RateLimiter(permitsPerSecond: 1_000))
  }

  @Test("A network failure from nativeTransactions is attributed to .blockExplorer")
  func nativeTransactionsErrorIsAttributed() async throws {
    let client = makeFailingClient()
    do {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .blockExplorer)
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }

  @Test("A network failure from internalTransactions is attributed to .blockExplorer")
  func internalTransactionsErrorIsAttributed() async throws {
    let client = makeFailingClient()
    do {
      _ = try await client.internalTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .blockExplorer)
    } catch {
      Issue.record("Expected WalletSyncError, got \(error)")
    }
  }
}

/// Dedicated URLProtocol stub for `LiveBlockscoutClientAttributionTests`, with
/// its own static handler state so it cannot race `BlockscoutURLProtocolStub`
/// (used by the separate, `.serialized` `LiveBlockscoutClientTests` suite) or
/// any other suite's stub when Swift Testing runs suites in parallel. This
/// suite is not `.serialized`, so its two tests can run concurrently against
/// each other; both assign the handler before invoking the client and neither
/// reads the other's assignment, so that's safe without further locking.
private class BlockscoutAttributionURLProtocolStub: URLProtocol {
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
    guard let handler = BlockscoutAttributionURLProtocolStub.requestHandler else {
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
