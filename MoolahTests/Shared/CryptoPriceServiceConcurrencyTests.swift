// MoolahTests/Shared/CryptoPriceServiceConcurrencyTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Regression coverage for the actor-reentrancy race in
/// `CryptoPriceService.price(for:mapping:on:)` and `prices(for:mapping:in:)`.
///
/// Both methods stash `(instrument, mapping)` into `pendingFetchContext[id]` for
/// the duration of the call so the window-only `fetchAndMerge` plug can recover
/// the provider mapping. The original code stashed into a single slot and
/// `defer`-cleared it. When two concurrent calls share the same instrument id,
/// the first to finish ran its `defer` and cleared the slot — stripping the
/// context out from under the second call, which was still looping and about to
/// invoke `fetchAndMerge` for a subsequent window (→ `assertionFailure` / no-op).
///
/// The fix ref-counts the context so it survives until the LAST concurrent
/// same-id call finishes. `pendingFetchContextIsRefCounted` proves that
/// invariant deterministically at the retain/release level — which is the only
/// reliable way to test it: an end-to-end concurrency test cannot isolate the
/// race, because same-token fetch *coalescing* (`fetchWindowCoalesced`) causes
/// the second caller to subscribe to the first caller's in-flight extension
/// task rather than issue its own window fetch, so the code path that needs the
/// stripped context is masked by the shared round-trip and its outcome depends
/// on unobservable continuation-resumption order. `concurrentSameIdLookups`
/// exercises the public API concurrently as a companion smoke test (no crash /
/// deadlock, both callers get the right price under coalescing).
@Suite("CryptoPriceService concurrency")
struct CryptoPriceServiceConcurrencyTests {
  // MARK: - Shared fixtures

  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  // MARK: - Test double

  /// Wraps `FixedCryptoPriceClient` but introduces a 40 ms suspension on every
  /// `dailyPrices` call. The delay keeps the extension task alive long enough
  /// for a second concurrent caller to reach `fetchWindowCoalesced` and coalesce
  /// on the in-flight task — making the concurrent path deterministic without
  /// relying on a specific scheduler interleaving.
  private struct DelayingCryptoPriceClient: CryptoPriceClient, Sendable {
    nonisolated let syncProvider: SyncProvider = .coinGecko
    private let inner: FixedCryptoPriceClient

    init(prices: [String: [String: Decimal]]) {
      self.inner = FixedCryptoPriceClient(prices: prices)
    }

    func dailyPrice(
      for mapping: CryptoProviderMapping, on date: Date
    ) async throws -> Decimal {
      try await Task.sleep(for: .milliseconds(40))
      return try await inner.dailyPrice(for: mapping, on: date)
    }

    func dailyPrices(
      for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
    ) async throws -> [String: Decimal] {
      try await Task.sleep(for: .milliseconds(40))
      return try await inner.dailyPrices(for: mapping, in: range)
    }

    func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
      [:]
    }
  }

  // MARK: - Ref-count lifecycle (the fix's invariant)

  /// Directly drives the retain/release lifecycle two concurrent same-id price
  /// calls would perform, and asserts the context survives the first release and
  /// is cleared only by the last. This is the exact invariant the ref-count fix
  /// adds; on the pre-fix single-slot `defer { context = nil }` the first
  /// release would clear the context (the mid assertion would fail).
  @Test("pendingFetchContext survives until the last concurrent same-id release")
  func pendingFetchContextIsRefCounted() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(clients: [], database: database)

    // Two concurrent same-id callers each retain the shared context.
    await service.retainPendingFetchContext(
      for: ethInstrument.id, instrument: ethInstrument, mapping: ethMapping)
    await service.retainPendingFetchContext(
      for: ethInstrument.id, instrument: ethInstrument, mapping: ethMapping)
    #expect(await service.pendingFetchContext[ethInstrument.id] != nil)

    // The first caller finishes and releases: the context must SURVIVE for the
    // still-in-flight sibling. This is precisely what broke before the fix.
    await service.releasePendingFetchContext(for: ethInstrument.id)
    #expect(await service.pendingFetchContext[ethInstrument.id] != nil)

    // Only the last caller's release clears it.
    await service.releasePendingFetchContext(for: ethInstrument.id)
    #expect(await service.pendingFetchContext[ethInstrument.id] == nil)
  }

  /// A balanced retain/release for a single caller clears the context.
  @Test("single retain/release clears the context")
  func singleRetainReleaseClearsContext() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(clients: [], database: database)

    await service.retainPendingFetchContext(
      for: ethInstrument.id, instrument: ethInstrument, mapping: ethMapping)
    await service.releasePendingFetchContext(for: ethInstrument.id)
    #expect(await service.pendingFetchContext[ethInstrument.id] == nil)
  }

  /// An over-release (more releases than retains) is a safe no-op: it must not
  /// trap or leave a negative count that a later retain would have to climb back
  /// out of, so a subsequent retain still takes effect normally.
  @Test("over-release with no outstanding retain is a safe no-op")
  func overReleaseIsNoOp() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(clients: [], database: database)

    // Release with no outstanding retain must not trap or wedge the slot.
    await service.releasePendingFetchContext(for: ethInstrument.id)
    #expect(await service.pendingFetchContext[ethInstrument.id] == nil)

    // A later retain still takes effect (no negative-count wedge), and its
    // matching release clears the context.
    await service.retainPendingFetchContext(
      for: ethInstrument.id, instrument: ethInstrument, mapping: ethMapping)
    #expect(await service.pendingFetchContext[ethInstrument.id] != nil)
    await service.releasePendingFetchContext(for: ethInstrument.id)
    #expect(await service.pendingFetchContext[ethInstrument.id] == nil)
  }

  // MARK: - Concurrent public-API smoke test

  /// Two concurrent lookups for the SAME instrument and SAME date. They both
  /// retain the shared context (ref-count → 2), coalesce on a single provider
  /// round-trip via `fetchWindowCoalesced`, and each must resolve to the correct
  /// price — proving concurrent same-id calls neither crash nor deadlock and
  /// that the ref-counted context is intact for both callers. Using one date
  /// keeps the assertion independent of which call happens to own the fetch.
  @Test("concurrent same-instrument same-date lookups coalesce and both resolve")
  func concurrentSameIdLookups() async throws {
    let frozenNow = date("2024-02-01")
    let utc = try #require(TimeZone(identifier: "UTC"))
    let requestedDate = date("2024-01-20")

    let client = DelayingCryptoPriceClient(prices: [
      "1:native": ["2024-01-20": dec("2000.00")]
    ])

    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(
      clients: [client],
      database: database,
      now: { frozenNow },
      timeZone: utc
    )

    async let priceA = service.price(for: ethInstrument, mapping: ethMapping, on: requestedDate)
    async let priceB = service.price(for: ethInstrument, mapping: ethMapping, on: requestedDate)

    let (resolvedA, resolvedB) = try await (priceA, priceB)

    #expect(resolvedA == dec("2000.00"))
    #expect(resolvedB == dec("2000.00"))
  }

  // MARK: - Helpers

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Invalid ISO date literal: \(string)")
    }
    return result
  }
}
