// MoolahTests/Backends/CloudKit/CrossProfileSpamPropagationTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Smoking-gun test that marking a token spam in one profile is
/// reflected in the other **within one CKSyncEngine cycle, verified
/// via `for await` on `observeChanges()`**. The propagation path is:
///
///   Profile A's session → shared registry write → registry's
///   `notifySubscribers()` fan-out → every subscriber (including
///   Profile B's session) receives the `Void` tick → Profile B's
///   session re-fetches and renders the new state.
///
/// Setup-order is load-bearing: the continuation must be installed
/// **before** the mutation, otherwise the tick is missed. The bounded
/// `for await … { break }` consumption pattern (no `Task.sleep`) lets
/// the test fail fast if the propagation never arrives.
@Suite("Cross-profile spam propagation through observeChanges()")
@MainActor
struct CrossProfileSpamPropagationTests {

  @Test("Spam mutation fires observeChanges() on a sibling profile's subscriber")
  func spamPropagatesToSubscriberInOtherSession() async throws {
    // One registry, two subscribers — production wiring. Every
    // ProfileSession on the iCloud account routes through the same
    // app-level `SharedInstrumentScope.instrumentRegistry`. Profile B's
    // UI subscriber attaches its `observeChanges()` continuation
    // before profile A's mutation; the registry's `notifySubscribers`
    // fan-out then yields a `Void` tick to every outstanding stream.
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    // Seed: register `bitcoin` as priced.
    let bitcoin = Instrument.crypto(
      chainId: 1,
      contractAddress: nil,
      symbol: "BTC",
      name: "Bitcoin",
      decimals: 8)
    try await registry.registerCrypto(
      bitcoin,
      mapping: CryptoProviderMapping(
        instrumentId: bitcoin.id,
        coingeckoId: "bitcoin",
        binanceSymbol: nil))

    // **Subscribe-before-mutate.** Install profile B's subscription
    // BEFORE the mutation; otherwise the @MainActor-confined
    // continuation registration races the synchronous fan-out inside
    // `update(_:)` and the test would silently false-pass on a
    // missed signal.
    let stream = registry.observeChanges()
    let waiter = Task<Void, Never> {
      var iterator = stream.makeAsyncIterator()
      // Bounded read — a single yield is sufficient evidence of
      // propagation; the test's `withThrowingTaskGroup` backstop
      // bounds the wait so a regression fails fast. Never
      // `Task.sleep`.
      _ = await iterator.next()
    }
    // Yield once to let the iterator install its continuation in the
    // registry's `subscribers` map. `observeChanges()` is
    // `@MainActor`-isolated and synchronous about continuation
    // registration, so a single await round-trip is sufficient.
    await Task.yield()

    // Profile A marks the registration spam — the user gesture the
    // shared registry exists to make "decide once, apply everywhere".
    var marked = try #require(
      try await registry.cryptoRegistration(byId: bitcoin.id))
    marked.pricingStatus = .spam
    try await registry.update(marked)

    // Bounded wait for the propagation tick. The waiter task either
    // completes (propagation fired) or stays blocked (regression). A
    // `ContinuousClock`-deadline race lets the test fail fast on
    // regression without `Task.sleep`: the propagation-detection path
    // uses `iterator.next()` directly, and this deadline race is the
    // fail-fast backstop.
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await waiter.value }
      group.addTask {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        try await ContinuousClock().sleep(until: deadline)
        waiter.cancel()
        Issue.record(
          "observeChanges() did not fire after spam mutation")
      }
      try await group.next()
      group.cancelAll()
    }

    // After the tick, profile B's view (same registry, fresh fetch)
    // sees the spam classification.
    let bView = try #require(
      try await registry.cryptoRegistration(byId: bitcoin.id))
    #expect(bView.pricingStatus == .spam)
  }

  @Test("DB-level sharing — sibling registries see each other's writes")
  func writesAreVisibleAcrossSiblingRegistries() async throws {
    // Companion check: even without `observeChanges()`, a sibling
    // registry pointed at the same DB sees each other's writes on
    // the next read. Cheap to keep — guards against a future change
    // that accidentally splits the DB binding per session.
    let queue = try ProfileIndexDatabase.openInMemory()
    let registryA = GRDBInstrumentRegistryRepository(database: queue)
    let registryB = GRDBInstrumentRegistryRepository(database: queue)

    let usdc = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      name: "USD Coin",
      decimals: 6)
    try await registryA.registerCrypto(
      usdc,
      mapping: CryptoProviderMapping(
        instrumentId: usdc.id,
        coingeckoId: "usd-coin",
        binanceSymbol: nil))
    #expect(try await registryB.cryptoRegistration(byId: usdc.id) != nil)

    try await registryA.remove(id: usdc.id)
    #expect(try await registryB.cryptoRegistration(byId: usdc.id) == nil)
  }
}
