import Foundation

// MARK: - PriceSeriesOrchestrating conformance

/// Routes `CryptoPriceService`'s daily price-series orchestration through the
/// shared `PriceSeriesOrchestrating` default methods. The actor's stored
/// `caches`, `hydrated`, `now`, `timeZone`, `dateFormatter`, and `plannerConfig`
/// satisfy the protocol's value requirements directly; the methods below plug
/// in the genuine crypto differences (the 4-provider fetch + coalescing and
/// the confirmed first-trade floor).
extension CryptoPriceService: PriceSeriesOrchestrating {
  typealias Cache = CryptoPriceCache

  /// Plug 1 — fetch one window through the 4-provider fallback chain and merge.
  /// Recovers the `(instrument, mapping)` the crypto fetch needs from
  /// `pendingFetchContext` (stashed by the thin `price`/`prices` call-throughs).
  /// `fetchWindowCoalesced` shares an in-flight round-trip via `extensionTasks`
  /// and persists the merged delta. A missing context (no active call for this
  /// key) is a no-op — the window loop then treats it as no-progress.
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
    guard let context = pendingFetchContext[instrumentKey] else {
      assertionFailure(
        "fetchAndMerge invoked without pendingFetchContext for \(instrumentKey)")
      return
    }
    try await fetchWindowCoalesced(
      instrument: context.instrument, mapping: context.mapping, fetchInterval: window)
  }

  /// Plug 2a — the confirmed first-trade floor (`YYYY-MM-DD`), if known.
  func firstTradeFloor(for instrumentKey: String) -> String? {
    caches[instrumentKey]?.firstTradedOn
  }

  /// Plug 2b — confirm+persist the first-trade floor on a clean backward
  /// exhaustion. Wraps the existing `confirmFirstTradedOnIfExhausted`.
  func confirmFirstTradeOnBackwardExhaustion(
    instrumentKey: String, lastFetchError: (any Error)?
  ) async throws {
    try await confirmFirstTradedOnIfExhausted(
      tokenId: instrumentKey, lastFetchError: lastFetchError)
  }

  /// Hydrate `caches[instrumentKey]` + insert into `hydrated` from SQL.
  func hydrate(instrumentKey: String) async throws {
    try await loadCache(tokenId: instrumentKey)
  }

  func belowFloorError(instrumentKey: String, date: String) -> any Error {
    CryptoPriceError.beforeFirstTrade(tokenId: instrumentKey, date: date)
  }

  func noPriceError(instrumentKey: String, date: String) -> any Error {
    CryptoPriceError.noPriceAvailable(tokenId: instrumentKey, date: date)
  }
}
