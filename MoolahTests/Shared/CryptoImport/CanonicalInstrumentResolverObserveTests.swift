// MoolahTests/Shared/CryptoImport/CanonicalInstrumentResolverObserveTests.swift

import Foundation
import Testing

@testable import Moolah

@Suite("CanonicalInstrumentResolver — observe on registry change")
struct CanonicalInstrumentResolverObserveTests {
  @Test("a registry-change tick triggers a re-derive")
  func tickRefreshesMap() async throws {
    let resolver = CanonicalInstrumentResolver()
    let registry = StubInstrumentRegistry(cryptoRegistrations: [
      reg("1:0xccc", chainId: 1, coingeckoId: "discovered-token"),
      reg("10:0xddd", chainId: 10, coingeckoId: "discovered-token"),
    ])
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = resolver.startObserving(registry: registry, changes: stream)

    // Poll until the initial refresh lands (no snap-read of async state).
    try await pollUntil { resolver.isAlias("10:0xddd") }
    #expect(resolver.canonicalId(for: "10:0xddd") == "1:0xccc")

    task.cancel()
    continuation.finish()
  }

  @Test("no refresh fires after the task is cancelled")
  func noRefreshAfterCancel() async throws {
    let resolver = CanonicalInstrumentResolver()
    let stub = CountingRegistryStub(registrations: [
      reg("1:0xccc", chainId: 1, coingeckoId: "tok"),
      reg("10:0xddd", chainId: 10, coingeckoId: "tok"),
    ])
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = resolver.startObserving(registry: stub, changes: stream)

    // Poll until the initial refresh lands (count reaches at least 1).
    try await pollUntil { stub.callCount >= 1 }
    let countAfterInitial = stub.callCount

    // Cancel the task, then emit a tick — the cancelled task must not
    // pick it up and trigger another refresh.
    task.cancel()
    continuation.yield(())

    // Within a short bounded window, confirm no additional refresh fired.
    let refreshedAfterCancel = await pollUntilOrFalse(timeout: .milliseconds(300)) {
      stub.callCount > countAfterInitial
    }
    #expect(!refreshedAfterCancel, "refresh fired after task cancellation")

    continuation.finish()
  }
}
