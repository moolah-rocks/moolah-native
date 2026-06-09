import Foundation

/// Outcome of a background `warmRange` pass over a token's price history.
enum WarmOutcome: Equatable {
  /// Every uncovered sub-range fetched (or there was nothing to do).
  case filled
  /// A provider is rate-limited; retry after this deadline.
  case cooledDown(until: Date)
  /// No provider could supply data and there is no cooldown to wait on.
  case unavailable
}
