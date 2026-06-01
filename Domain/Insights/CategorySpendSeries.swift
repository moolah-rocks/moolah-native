import Foundation

/// One month of spend for a category, magnitude expressed as a positive
/// `Double` (the underlying `ExpenseBreakdown.totalExpenses` is a signed
/// negative sum; this flips it so larger = more spending).
struct MonthlySpendPoint: Sendable, Hashable {
  /// Financial month bucket, `YYYYMM`.
  let month: String
  /// First day of the bucket's calendar month (UTC midnight), for recency.
  let date: Date
  /// Positive spend magnitude in the reporting currency.
  let magnitude: Double
}

/// Builds per-category, gap-filled monthly spend series from the backend's
/// `ExpenseBreakdown` rows. Detectors need *evenly spaced* series (a month
/// with no spend is a real zero, not a missing sample), so the gaps between
/// the first and last observed month are filled with zeros.
enum CategorySpendSeries {
  /// Per-category series keyed by `categoryId` (a `nil` category id is
  /// folded under a synthetic all-zero UUID so it can still be keyed).
  /// Each series is sorted ascending by month with interior gaps zero-filled.
  static func build(
    from breakdown: [ExpenseBreakdown], reportingCurrency: Instrument
  ) -> [UUID: [MonthlySpendPoint]] {
    let byCategory = Dictionary(grouping: breakdown) { $0.categoryId ?? Self.uncategorizedKey }
    var result: [UUID: [MonthlySpendPoint]] = [:]
    for (categoryId, rows) in byCategory {
      result[categoryId] = series(from: rows)
    }
    return result
  }

  /// The combined all-category monthly spend series (gap-filled).
  static func total(
    from breakdown: [ExpenseBreakdown]
  ) -> [MonthlySpendPoint] {
    series(from: breakdown)
  }

  /// Sentinel category id used to key uncategorized spend.
  static let uncategorizedKey =
    UUID(
      uuidString: "00000000-0000-0000-0000-0000000000FF") ?? UUID()

  private static func series(from rows: [ExpenseBreakdown]) -> [MonthlySpendPoint] {
    var magnitudeByMonth: [String: Double] = [:]
    for row in rows {
      let signed = Double(truncating: row.totalExpenses.quantity as NSDecimalNumber)
      // Flip the negative expense sum to a positive spend magnitude; a
      // net-refund month (positive sum) clamps to zero rather than going
      // negative, which would distort the trend / anomaly maths.
      magnitudeByMonth[row.month, default: 0] += max(-signed, 0)
    }
    guard let first = magnitudeByMonth.keys.min(),
      let last = magnitudeByMonth.keys.max()
    else { return [] }

    var points: [MonthlySpendPoint] = []
    var cursor = first
    while true {
      let date = monthDate(cursor) ?? Date.distantPast
      points.append(
        MonthlySpendPoint(month: cursor, date: date, magnitude: magnitudeByMonth[cursor] ?? 0))
      if cursor == last { break }
      guard let next = nextMonth(cursor) else { break }
      cursor = next
    }
    return points
  }

  /// `YYYYMM` → first-of-month UTC date.
  static func monthDate(_ month: String) -> Date? {
    guard month.count == 6, let year = Int(month.prefix(4)),
      let monthNumber = Int(month.suffix(2))
    else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = monthNumber
    components.day = 1
    return InsightContext.defaultCalendar.date(from: components)
  }

  /// Increment a `YYYYMM` bucket by one month, rolling the year over.
  static func nextMonth(_ month: String) -> String? {
    guard month.count == 6, let year = Int(month.prefix(4)),
      let monthNumber = Int(month.suffix(2)), (1...12).contains(monthNumber)
    else { return nil }
    let nextYear = monthNumber == 12 ? year + 1 : year
    let nextMonthNumber = monthNumber == 12 ? 1 : monthNumber + 1
    return String(format: "%04d%02d", nextYear, nextMonthNumber)
  }
}
