import Foundation

/// Ambient parameters every detector needs: the reference "now", the
/// reporting currency all monetary inputs are denominated in, and the
/// calendar used for day/month bucketing. `now` is injected (never read
/// from `Date()` inside a detector) so detector tests are deterministic —
/// see `guides/TEST_GUIDE.md`.
struct InsightContext: Sendable {
  let now: Date
  let reportingCurrency: Instrument
  let calendar: Calendar

  /// The user's financial-month boundary day (1–31), mirroring
  /// `AnalysisStore.monthEnd`. Detectors that bucket by financial month
  /// use it; most rely on the pre-bucketed `MonthlyIncomeExpense` instead.
  let financialMonthEnd: Int

  init(
    now: Date,
    reportingCurrency: Instrument,
    calendar: Calendar = InsightContext.defaultCalendar,
    financialMonthEnd: Int = 1
  ) {
    self.now = now
    self.reportingCurrency = reportingCurrency
    self.calendar = calendar
    self.financialMonthEnd = financialMonthEnd
  }

  /// A UTC Gregorian calendar — matches how balances and aggregates are
  /// bucketed in the backend (`DATE(...)` is UTC midnight).
  static var defaultCalendar: Calendar {
    Calendar.utc
  }

  /// Zero amount in the reporting currency — a convenience for detectors
  /// that accumulate sums.
  var zero: InstrumentAmount { .zero(instrument: reportingCurrency) }

  /// Whole days from `date` to `now`, rounded toward zero. Negative for
  /// future dates.
  func daysSince(_ date: Date) -> Int {
    calendar.dateComponents([.day], from: date, to: now).day ?? 0
  }

  /// Whole days from `now` to `date`. Negative for past dates.
  func daysUntil(_ date: Date) -> Int {
    calendar.dateComponents([.day], from: now, to: date).day ?? 0
  }

  /// Format a signed reporting-currency quantity for narration.
  func formatted(_ quantity: Decimal) -> String {
    InstrumentAmount(quantity: quantity, instrument: reportingCurrency).formatted
  }

  /// Format an amount for narration. Falls back to the reporting currency
  /// label when the amount carries a different instrument.
  func formatted(_ amount: InstrumentAmount) -> String {
    amount.formatted
  }

  /// Ballpark rendering of a reporting-currency quantity: rounds to ~3
  /// significant figures and drops cents. Delegates to
  /// `InstrumentAmount.formattedApproximate`.
  func formattedApproximate(_ quantity: Decimal) -> String {
    InstrumentAmount(quantity: quantity, instrument: reportingCurrency).formattedApproximate
  }

  /// Month and year rendered in the same calendar and time zone used to
  /// bucket insight data.
  func formattedMonth(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        .locale(Locale(identifier: "en_US_POSIX"))
        .month(.wide)
        .year())
  }

  /// A recent day rendered with enough context to distinguish it from every
  /// other occurrence of the same weekday.
  func formattedDay(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        .locale(Locale(identifier: "en_US_POSIX"))
        .weekday(.wide)
        .month(.abbreviated)
        .day())
  }

  func formattedDate(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        .locale(Locale(identifier: "en_US_POSIX"))
        .month(.abbreviated)
        .day()
        .year())
  }

  /// A user-entered date-only value, rendered in the device calendar that
  /// supplied it. Earmark target dates come directly from a SwiftUI
  /// `DatePicker`, rather than the UTC day tokens used by analysis data.
  func formattedLocalDay(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(calendar: .current, timeZone: .current)
        .locale(Locale(identifier: "en_US_POSIX"))
        .month(.abbreviated)
        .day()
        .year())
  }

  func formattedFinancialMonth(_ key: String) -> String? {
    guard let endMonth = FinancialMonth.date(forKey: key) else { return nil }
    if financialMonthEnd == 31 {
      return formattedMonth(endMonth)
    }
    let calendar = Calendar.utc
    guard
      let previousMonth = calendar.date(byAdding: .month, value: -1, to: endMonth),
      let previousRange = calendar.range(of: .day, in: .month, for: previousMonth),
      let endRange = calendar.range(of: .day, in: .month, for: endMonth),
      let previousCutoff = calendar.date(
        bySetting: .day,
        value: min(financialMonthEnd, previousRange.count),
        of: previousMonth),
      let start = calendar.date(byAdding: .day, value: 1, to: previousCutoff),
      let end = calendar.date(
        bySetting: .day,
        value: min(financialMonthEnd, endRange.count),
        of: endMonth)
    else { return nil }
    return Self.formattedRange(start: start, end: end)
  }

  private static func formattedRange(start: Date, end: Date) -> String {
    let calendar = Calendar.utc
    let startYear = calendar.component(.year, from: start)
    let endYear = calendar.component(.year, from: end)
    let startText = start.formatted(
      Date.FormatStyle(calendar: calendar, timeZone: .gmt)
        .locale(Locale(identifier: "en_US_POSIX"))
        .month(.abbreviated)
        .day())
    let endText = end.formatted(
      Date.FormatStyle(calendar: calendar, timeZone: .gmt)
        .locale(Locale(identifier: "en_US_POSIX"))
        .month(.abbreviated)
        .day())
    if startYear == endYear {
      return "\(startText) – \(endText), \(endYear)"
    }
    return "\(startText), \(startYear) – \(endText), \(endYear)"
  }
}
