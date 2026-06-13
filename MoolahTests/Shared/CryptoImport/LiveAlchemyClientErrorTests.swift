// MoolahTests/Shared/CryptoImport/LiveAlchemyClientErrorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveAlchemyClient — error mapping")
struct LiveAlchemyClientErrorTests {
  @Test
  func httpUnauthorizedMapsToInvalidApiKey() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 401)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.invalidApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .invalidApiKey)
      #expect(error.provider == .alchemy)
    }
  }

  @Test
  func httpForbiddenMapsToInvalidApiKey() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 403)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.invalidApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .invalidApiKey)
      #expect(error.provider == .alchemy)
    }
  }

  @Test
  func httpTooManyRequestsMapsToRateLimitedWithRetryAfter() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(
        for: request,
        statusCode: 429,
        headerFields: ["Retry-After": "10"]
      )
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let error as WalletSyncError {
      guard case .rateLimited(let retryAfter) = error.kind else {
        Issue.record("Expected .rateLimited kind, got \(error.kind)")
        return
      }
      let date = try #require(retryAfter)
      #expect(date.timeIntervalSinceNow > 5)
      #expect(date.timeIntervalSinceNow < 15)
    }
  }

  @Test
  func httpTooManyRequestsWithoutRetryAfterMapsToRateLimitedWithNilDate() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 429)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let error as WalletSyncError {
      #expect(error.kind == .rateLimited(retryAfter: nil))
      #expect(error.provider == .alchemy)
    }
  }

  @Test
  func httpServerErrorMapsToNetworkError() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 503)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.network")
    } catch let error as WalletSyncError {
      guard case .network(let description) = error.kind else {
        Issue.record("Expected .network kind, got \(error.kind)")
        return
      }
      #expect(description.contains("503"))
    }
  }

  @Test
  func transportFailureMapsToNetworkError() async throws {
    let client = AlchemyTestSupport.makeClient { _ in
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.network")
    } catch let error as WalletSyncError {
      guard case .network(let description) = error.kind else {
        Issue.record("Expected .network kind, got \(error.kind)")
        return
      }
      #expect(description.isEmpty == false)
    }
  }

  @Test
  func malformedJSONMapsToProviderMalformedResponse() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.okResponse(for: request)
      return (response, Data("not json".utf8))
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.providerMalformedResponse")
    } catch let error as WalletSyncError {
      #expect(error.kind == .providerMalformedResponse(stage: "getAssetTransfers"))
      #expect(error.provider == .alchemy)
    }
  }

  // MARK: - Empty API key pre-flight
  //
  // When `ProfileSession.resolveAlchemyApiKey()` returns nil the wiring
  // passes an empty string into `LiveAlchemyClient`. Without a pre-flight
  // guard the URL becomes `https://<network>.g.alchemy.com/v2/` (nothing
  // after the slash), Alchemy returns 401, and the response validator
  // throws `.invalidApiKey` — misleading because the key is missing, not
  // invalid. The tests below pin the pre-flight `.missingApiKey` throw
  // for every public method that hits the network. They use a handler
  // that records whether the network was touched; on a correct
  // pre-flight the recorder stays empty.

  @Test
  func emptyApiKeyShortCircuitsGetAssetTransfersWithMissingApiKey() async throws {
    let touched = NetworkTouchRecorder()
    let client = AlchemyTestSupport.makeClient(apiKey: "") { request in
      touched.markTouched()
      let response = AlchemyTestSupport.response(for: request, statusCode: 401)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.missingApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .missingApiKey)
      #expect(error.provider == .alchemy)
    }
    #expect(touched.wasTouched == false)
  }

  @Test
  func emptyApiKeyShortCircuitsGetTransactionReceiptWithMissingApiKey() async throws {
    let touched = NetworkTouchRecorder()
    let client = AlchemyTestSupport.makeClient(apiKey: "") { request in
      touched.markTouched()
      let response = AlchemyTestSupport.response(for: request, statusCode: 401)
      return (response, Data())
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xdead"
      )
      Issue.record("Expected WalletSyncError.missingApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .missingApiKey)
      #expect(error.provider == .alchemy)
    }
    #expect(touched.wasTouched == false)
  }
}

/// Minimal lock-protected flag the empty-API-key tests use to assert the
/// pre-flight guard never reaches the URLProtocol stub.
private final class NetworkTouchRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var touched = false

  func markTouched() {
    lock.lock()
    defer { lock.unlock() }
    touched = true
  }

  var wasTouched: Bool {
    lock.lock()
    defer { lock.unlock() }
    return touched
  }
}
