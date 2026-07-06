// MoolahTests/Shared/CryptoImport/LiveAlchemyClientKeyProviderTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pins the contract that `LiveAlchemyClient` resolves its API key from
/// the injected closure on **every** request — never from a value
/// captured at construction. Two properties both ride on this:
///
/// 1. **Freshness**: a key added in settings *after* the client was
///    constructed becomes visible on the very next call. (Prior to
///    Bug 5's fix, the client stored the key as a `let` field, so a
///    user who added a valid key after launch still saw Sync now
///    fail with HTTP 401 against the stale empty-string key.)
/// 2. **Memory residency**: the resolved key only exists on the local
///    stack frame of the in-flight request. The client deliberately
///    has no instance-level field that could outlive the call. The
///    `.missingApiKey` short-circuit happens before any network or
///    URL-construction work, so an unset key is never even composed
///    into a URL.
///
/// The tests assert (1) directly with a mutable provider; (2) is
/// enforced structurally by the implementation and reviewed at PR
/// time — there's nothing to assert about object lifetimes, but the
/// freshness test catches any future regression that re-introduces
/// instance-level caching.
@Suite("LiveAlchemyClient — key provider freshness")
struct LiveAlchemyClientKeyProviderTests {
  @Test("Key added after construction is visible on the next call")
  func keyAddedAfterConstructionVisibleOnNextCall() async throws {
    let key = MutableKey()
    let recorder = RequestURLRecorder()
    let client = AlchemyTestSupport.makeClient(
      apiKeyProvider: { key.value },
      handler: { request in
        recorder.record(request.url?.absoluteString ?? "")
        let payload = #"{"jsonrpc":"2.0","id":1,"result":{"transfers":[]}}"#
        return (
          AlchemyTestSupport.okResponse(for: request),
          Data(payload.utf8)
        )
      })
    // Initial state: provider returns nil → first call short-circuits
    // with `.missingApiKey` before any network work.
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0, toBlock: nil)
      Issue.record("Expected WalletSyncError.missingApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .missingApiKey)
      #expect(error.provider == .alchemy)
    }
    #expect(recorder.urls.isEmpty, "Pre-flight should not touch the network")

    // User adds a key in settings — provider now returns it. The next
    // call must succeed without rebuilding the client.
    key.set("freshly-added-key")
    let transfers = try await client.getAssetTransfers(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0, toBlock: nil)
    #expect(transfers.isEmpty)

    // The request URL embedded the newly-resolved key — proves the
    // provider was consulted on this call, not a captured stale value.
    #expect(recorder.urls.allSatisfy { $0.contains("freshly-added-key") })
    #expect(!recorder.urls.isEmpty)
  }

  @Test("Key removed after a successful call short-circuits the next one")
  func keyRemovedAfterSuccessShortCircuitsNextCall() async throws {
    let key = MutableKey(initial: "initially-valid")
    let client = AlchemyTestSupport.makeClient(
      apiKeyProvider: { key.value },
      handler: { request in
        let payload = #"{"jsonrpc":"2.0","id":1,"result":{"transfers":[]}}"#
        return (
          AlchemyTestSupport.okResponse(for: request),
          Data(payload.utf8)
        )
      })
    _ = try await client.getAssetTransfers(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0, toBlock: nil)

    // Simulate a settings flow that clears the keychain.
    key.set(nil)
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0, toBlock: nil)
      Issue.record("Expected WalletSyncError.missingApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .missingApiKey)
      #expect(error.provider == .alchemy)
    }
  }
}

/// Lock-protected mutable container for the test's "key changes
/// mid-session" scenario. The closure passed to `LiveAlchemyClient` must
/// be `@Sendable`, so plain `var` capture won't compile under strict
/// concurrency. Matches the lock-then-read pattern used by other
/// recording test doubles in this directory.
private final class MutableKey: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?

  init(initial: String? = nil) { self.stored = initial }

  var value: String? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ newValue: String?) {
    lock.lock()
    defer { lock.unlock() }
    stored = newValue
  }
}

/// Lock-protected URL recorder for the freshness assertion. Avoids the
/// shared `AlchemyURLProtocolStub.lastRequest` static (which only
/// captures when handlers explicitly call `captureRequest`) and gives
/// the test a deterministic, ordered list of URLs the request handler
/// saw.
private final class RequestURLRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var urlsBacking: [String] = []

  func record(_ url: String) {
    lock.lock()
    defer { lock.unlock() }
    urlsBacking.append(url)
  }

  var urls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return urlsBacking
  }
}
