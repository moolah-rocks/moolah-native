import Foundation

// MARK: - PriceSeriesOrchestrating conformance

/// Routes `StockPriceService`'s daily price-series orchestration through the
/// shared `PriceSeriesOrchestrating` default methods. The actor's stored
/// `caches`, `hydrated`, `now`, `timeZone`, `dateFormatter`, and `plannerConfig`
/// satisfy the protocol's value requirements directly; the methods below plug
/// in stock's single-Yahoo-client fetch and its listing-currency quote
/// denomination. Stock has no first-trade concept, so the floor plugs are
/// inert (`nil` floor, no-op confirmation).
extension StockPriceService: PriceSeriesOrchestrating {
  typealias Cache = StockPriceCache

  /// Plug 1 — fetch one window via the single Yahoo client and merge+persist.
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
    try await fetchAndMerge(
      ticker: instrumentKey, from: window.lowerBound, to: window.upperBound)
  }

  /// Plug 2 — the ticker's listing currency. `nil` on a cold cache; the
  /// currency is discovered at fetch time and stored in the cache.
  func quote(for instrumentKey: String) -> Instrument? { caches[instrumentKey]?.instrument }

  /// Plug 3a — stock has no first-trade floor.
  func firstTradeFloor(for instrumentKey: String) -> String? { nil }

  /// Plug 3b — no first-trade floor to confirm for stock; no-op.
  func confirmFirstTradeOnBackwardExhaustion(
    instrumentKey: String, lastFetchError: (any Error)?
  ) async throws {}

  /// Hydrate `caches[instrumentKey]` + insert into `hydrated` from SQL.
  func hydrate(instrumentKey: String) async throws {
    try await loadCache(ticker: instrumentKey)
  }

  /// Never invoked (the floor is always `nil`), but the factory must return a
  /// real error to satisfy the protocol.
  func belowFloorError(instrumentKey: String, date: String) -> any Error {
    StockPriceError.noPriceAvailable(ticker: instrumentKey, date: date)
  }

  func noPriceError(instrumentKey: String, date: String) -> any Error {
    StockPriceError.noPriceAvailable(ticker: instrumentKey, date: date)
  }
}
