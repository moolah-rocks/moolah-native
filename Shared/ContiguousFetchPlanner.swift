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
  /// - earliest/latest: current contiguous bounds as `DateKey`, or `nil`
  ///   when the series is empty (cold cache).
  /// - requested: the `DateKey` the caller needs.
  /// - today: the `DateKey` for "now" (callers pass `now()`'s day). Forward
  ///   windows may extend up to `today + forwardBuffer` — providers tolerate
  ///   slight future dates and clamp, so this never withholds a
  ///   forward-timezone market's already-published close.
  /// - windowDays: max span of a single window (≈30). Large enough to clear
  ///   a weekend/holiday run, small enough that a provider serves it whole.
  /// - forwardBuffer: days past `today` a forward window may reach (≈2).
  static func nextWindow(
    earliest: Int32?, latest: Int32?,
    requested: Int32, today: Int32,
    windowDays: Int, forwardBuffer: Int
  ) -> ClosedRange<Int32>? {
    guard let earliest, let latest else {
      return coldWindow(
        requested: requested, today: today,
        windowDays: windowDays, forwardBuffer: forwardBuffer)
    }
    if requested >= earliest && requested <= latest { return nil }
    return nil  // filled in by later tasks
  }

  /// Adds `days` calendar days to a `DateKey` (`Int32` yyyymmdd), crossing
  /// month and year boundaries correctly. Never use raw `Int32 ± n` on a
  /// `DateKey` — the encoding is not contiguous across month ends.
  static func addingDays(_ days: Int, to key: Int32) -> Int32 {
    let iso = DateKey.isoString(key)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone.utc
    guard let date = formatter.date(from: iso),
      let shifted = Calendar.utc.date(byAdding: .day, value: days, to: date),
      let result = DateKey.from(isoString: formatter.string(from: shifted))
    else { return key }
    return result
  }

  private static func coldWindow(
    requested: Int32, today: Int32, windowDays: Int, forwardBuffer: Int
  ) -> ClosedRange<Int32>? {
    return nil  // filled in by Task 4
  }
}
