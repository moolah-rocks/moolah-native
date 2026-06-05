import Foundation

/// UTC-anchored financial-month bucket key (`YYYYMM`) shared by every
/// analysis path that groups transactions into months respecting the
/// user's configured `monthEnd` cut-off.
///
/// Anchored to a UTC Gregorian calendar so a transaction whose UTC
/// `Date()` represents e.g. `2025-03-25` lands in the same financial-month
/// bucket regardless of the runner's local timezone. A
/// `Calendar.current`-based implementation reads the previous
/// local-time day in negative-UTC zones (e.g. America/New_York) and
/// mis-buckets rows on the boundary day; this helper avoids that
/// drift by pinning the calendar to UTC.
///
/// `GRDBAnalysisRepository.financialMonth` forwards to this helper so
/// every aggregation path that buckets months sees the same
/// UTC-anchored result.
enum FinancialMonth {
  /// Compute the financial-month key (`YYYYMM`) for `date`, respecting
  /// the user's configured `monthEnd` cut-off.
  ///
  /// Transactions whose UTC day-of-month is greater than `monthEnd` roll
  /// into the next calendar month's bucket; transactions on or before
  /// `monthEnd` stay in the current month. December rollovers wrap to
  /// the next year. `monthEnd: 31` keeps every UTC day in its own
  /// calendar month.
  static func key(for date: Date, monthEnd: Int) -> String {
    let calendar = Calendar.utc
    let dayOfMonth = calendar.component(.day, from: date)
    let adjustedDate: Date
    if dayOfMonth > monthEnd {
      guard let shifted = calendar.date(byAdding: .month, value: 1, to: date) else {
        return defaultMonthKey(for: date, calendar: calendar)
      }
      adjustedDate = shifted
    } else {
      adjustedDate = date
    }
    let year = calendar.component(.year, from: adjustedDate)
    let month = calendar.component(.month, from: adjustedDate)
    return String(format: "%04d%02d", year, month)
  }

  private static func defaultMonthKey(for date: Date, calendar: Calendar) -> String {
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    return String(format: "%04d%02d", year, month)
  }

  /// Maps a `YYYYMM` bucket label back to the first day of that month at
  /// **noon UTC** — the inverse of `key(for:monthEnd:)` for display and
  /// charting.
  ///
  /// The result is a *positioning token*, not a timeline instant: it exists
  /// only so a month bucket can be placed on a date axis or ordered. It is
  /// anchored at noon rather than midnight so that even a downstream read in
  /// the device's local zone — a SwiftUI Charts axis, a stray
  /// `Calendar.current` — still reports the same calendar month in every
  /// timezone from UTC−12 to UTC+14. Returns nil for a malformed label.
  ///
  /// Never compare the returned `Date` for equality against a
  /// midnight-anchored instant (e.g. a `DATE(...)` balance date); the noon
  /// offset is deliberate and would never match.
  ///
  /// - Returns: nil if `label` is not exactly six ASCII digits, or if the
  ///   month component is outside 1...12.
  static func date(forKey label: String) -> Date? {
    guard label.count == 6, let year = Int(label.prefix(4)),
      let month = Int(label.suffix(2)), (1...12).contains(month)
    else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = 1
    components.hour = 12
    return Calendar.utc.date(from: components)
  }
}
