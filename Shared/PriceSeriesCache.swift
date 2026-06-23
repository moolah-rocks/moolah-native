import Foundation

/// The cache fields the shared `PriceSeriesOrchestrating` default methods
/// read and mutate. Abstracts only the common series state — NOT the
/// per-service meta (stock's `instrument`, crypto's `symbol` /
/// `firstTradedOn`), which the orchestration reaches through plugs.
protocol PriceSeriesCache: Sendable, Equatable {
  /// Contiguous lower bound, ISO `YYYY-MM-DD`.
  var earliestDate: String { get set }
  /// Contiguous upper bound, ISO `YYYY-MM-DD`.
  var latestDate: String { get set }
  /// `DateKey`-keyed daily values (close price in the cache's denomination).
  var prices: SortedDateSeries<Decimal> { get set }
}
