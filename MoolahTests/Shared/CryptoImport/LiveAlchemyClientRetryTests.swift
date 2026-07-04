// MoolahTests/Shared/CryptoImport/LiveAlchemyClientRetryTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers the bounded 429 retry on `LiveAlchemyClient`, which routes through
/// the shared `withRetry` backoff. The test client injects an instant no-op
/// `sleeper` (via `AlchemyTestSupport`), so the backoff runs without real
/// wall-clock delay. Directions are fetched sequentially (`from` then `to`),
/// so per-call request counts are deterministic.
@Suite("LiveAlchemyClient — 429 retry/backoff")
struct LiveAlchemyClientRetryTests {
  /// A JSON-RPC `alchemy_getAssetTransfers` success with no transfers and no
  /// continuation page — one request completes a direction.
  private static let emptyTransfers = Data(
    #"{"jsonrpc":"2.0","id":1,"result":{"transfers":[]}}"#.utf8)

  @Test
  func transientRateLimitIsRetriedThenSucceeds() async throws {
    let counter = CallCounter()
    let client = AlchemyTestSupport.makeClient { request in
      // Only the first request is throttled; the retry and everything after
      // succeed, so the call as a whole recovers.
      if counter.next() == 1 {
        return (AlchemyTestSupport.response(for: request, statusCode: 429), Data())
      }
      return (AlchemyTestSupport.okResponse(for: request), Self.emptyTransfers)
    }

    let transfers = try await client.getAssetTransfers(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)

    #expect(transfers.isEmpty)
    // from-page-1 (429 → retry → 200) + to-page-1 (200) = 3 requests.
    #expect(counter.total == 3)
  }

  @Test
  func sustainedRateLimitExhaustsRetriesThenSurfacesRateLimited() async throws {
    let counter = CallCounter()
    let client = AlchemyTestSupport.makeClient { request in
      _ = counter.next()
      return (AlchemyTestSupport.response(for: request, statusCode: 429), Data())
    }

    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let error as WalletSyncError {
      #expect(error.kind == .rateLimited(retryAfter: nil))
      #expect(error.provider == .alchemy)
    }
    // `retryPolicy.maxAttempts == 4`: 1 initial + 3 retries on the first
    // page, before the second direction is even reached.
    #expect(counter.total == 4)
  }

  @Test
  func cancellationDuringBackoffPropagatesInsteadOfBeingSwallowedAsRateLimited()
    async
  {
    // A cancellation thrown while backing off must surface as
    // `CancellationError`, never be recategorised as `.rateLimited`.
    let client = AlchemyTestSupport.makeClient(
      sleeper: { _ in throw CancellationError() },
      handler: { request in
        (AlchemyTestSupport.response(for: request, statusCode: 429), Data())
      }
    )

    await #expect(throws: CancellationError.self) {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
  }
}

/// Thread-safe call counter for the URLProtocol handler closure, which must
/// be `@Sendable`.
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
