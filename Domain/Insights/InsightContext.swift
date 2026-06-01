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
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    return calendar
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
}
