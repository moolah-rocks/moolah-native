import Foundation

// MARK: - PriceSeriesOrchestrating conformance

/// Routes `StockPriceService`'s daily price-series orchestration through the
/// shared `PriceSeriesOrchestrating` default methods. The actor's stored
/// `caches`, `hydrated`, `now`, `timeZone`, `dateFormatter`, and `plannerConfig`
/// satisfy the protocol's value requirements directly; the method below plugs
/// in stock's single-Yahoo-client fetch. Stock has no first-trade concept, so
/// it relies on the protocol's default no-floor plugs.
extension StockPriceService: PriceSeriesOrchestrating {
  typealias Cache = StockPriceCache

  /// Plug 1 — fetch one window via the single Yahoo client and merge+persist.
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
    try await fetchAndMerge(
      ticker: instrumentKey, from: window.lowerBound, to: window.upperBound)
  }

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
