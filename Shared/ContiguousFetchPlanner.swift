import Foundation

/// Plans the next **bounded, boundary-anchored** fetch window for a
/// contiguous date-keyed price/rate cache. Pure arithmetic on `DateKey`
/// (`Int32` yyyymmdd) — no I/O. Bounding the window is what keeps a cache
/// contiguous: a provider can only ever serve days inside a window the
/// planner already declared queried, so the cache's `[earliest, latest]`
/// can never advance past a day that was never fetched.
///
/// `nil` means "the requested date is already inside `[earliest, latest]`"
/// — the caller reads it via the prior-trading-day fallback, no fetch.
enum ContiguousFetchPlanner {
  /// Configuration shared across all window calculations for a given service.
  struct Config {
    /// Max span of a single window (≈30 days). Large enough to clear a
    /// weekend/holiday run, small enough that a provider serves it wholesale.
    let windowDays: Int
    /// Days past `today` a forward window may reach (≈2). Providers tolerate
    /// slight future dates and clamp, so this never withholds a
    /// forward-timezone market's already-published close.
    let forwardBuffer: Int
  }

  /// Shared formatter for `addingDays` — `[.withFullDate]`, UTC. Hoisted to a
  /// static so the hot per-window loop does not allocate an
  /// `ISO8601DateFormatter` on every call. `ISO8601DateFormatter`'s
  /// `date(from:)` / `string(from:)` are documented thread-safe and the
  /// formatter is configured once and never mutated, so `nonisolated(unsafe)`
  /// is sound here.
  nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone.utc
    return formatter
  }()

  /// Returns the next fetch window to issue, or `nil` when the requested date
  /// is already inside `[earliest, latest]` (read via prior-trading-day
  /// fallback, no fetch needed).
  ///
  /// - Parameters:
  ///   - earliest: current contiguous lower bound as `DateKey`, or `nil`
  ///     when the series is empty (cold cache).
  ///   - latest: current contiguous upper bound as `DateKey`, or `nil`
  ///     when the series is empty (cold cache).
  ///   - requested: the `DateKey` the caller needs.
  ///   - today: the `DateKey` for "now" (callers pass `now()`'s day).
  ///   - config: window sizing and forward-buffer constants.
  /// - Returns: the next fetch window as a `ClosedRange<Int32>`, or `nil`
  ///   when the requested date is already inside `[earliest, latest]`.
  static func nextWindow(
    earliest: Int32?,
    latest: Int32?,
    requested: Int32,
    today: Int32,
    config: Config
  ) -> ClosedRange<Int32>? {
    guard let earliest, let latest else {
      return coldWindow(requested: requested, today: today, config: config)
    }
    if requested >= earliest && requested <= latest { return nil }
    if requested > latest {
      let cap = min(requested, addingDays(config.forwardBuffer, to: today))
      let upper = min(addingDays(config.windowDays, to: latest), cap)
      // Anchor at `latest` itself so a stale latest-day tick is overwritten.
      guard latest <= upper else { return nil }
      return latest...upper
    }
    // requested < earliest: backward branch
    let lower = max(requested, addingDays(-config.windowDays, to: earliest))
    let upper = addingDays(-1, to: earliest)
    guard lower <= upper else { return nil }
    return lower...upper
  }

  /// Adds `days` calendar days to a `DateKey` (`Int32` yyyymmdd), crossing
  /// month and year boundaries correctly. Never use raw `Int32 ± n` on a
  /// `DateKey` — the encoding is not contiguous across month ends.
  static func addingDays(_ days: Int, to key: Int32) -> Int32 {
    let iso = DateKey.isoString(key)
    guard
      let date = dateFormatter.date(from: iso),
      let shifted = Calendar.utc.date(byAdding: .day, value: days, to: date),
      let result = DateKey.from(isoString: dateFormatter.string(from: shifted))
    else { return key }
    return result
  }

  /// Splits `range` into consecutive sub-ranges of at most `days` calendar
  /// days (UTC). Used by the price/rate services' `uncoveredSubRanges` to
  /// cap individual fetches so a horizon-restricted provider cannot jump the
  /// cache bounds over a void.
  static func chunked(_ range: ClosedRange<Date>, days: Int) -> [ClosedRange<Date>] {
    let cal = Calendar.utc
    var result: [ClosedRange<Date>] = []
    var start = range.lowerBound
    while start <= range.upperBound {
      let end: Date
      if let candidate = cal.date(byAdding: .day, value: days, to: start) {
        end = min(candidate, range.upperBound)
      } else {
        end = range.upperBound
      }
      result.append(start...end)
      guard let next = cal.date(byAdding: .day, value: 1, to: end) else { break }
      if next > range.upperBound { break }
      start = next
    }
    return result
  }

  private static func coldWindow(
    requested: Int32,
    today: Int32,
    config: Config
  ) -> ClosedRange<Int32>? {
    let end = min(requested, addingDays(config.forwardBuffer, to: today))
    let start = addingDays(-config.windowDays, to: end)
    guard start <= end else { return nil }
    return start...end
  }
}
