import Foundation

/// Conversion and day-bucketing helpers shared across the SQL-driven
/// analysis methods on `GRDBAnalysisRepository`
/// (`fetchExpenseBreakdown`, `fetchCategoryBalances`,
/// `fetchIncomeAndExpense`, `fetchDailyBalances`). Lifted into a
/// sibling extension so the main repository file stays small and so
/// every aggregation reuses the same day-string parser and the
/// (storageValue, instrument) → converted `InstrumentAmount` helper.
///
/// The helpers are static and free of stored-state coupling — taking
/// their dependencies as parameters so this sibling-file extension
/// doesn't reach into the main class's `private` storage.
extension GRDBAnalysisRepository {
  /// Day-string parser used by every SQL-driven method that aggregates
  /// `(DATE(t.date), …)`.
  ///
  /// SQLite's `DATE()` extracts the UTC calendar date of the stored
  /// timestamp (GRDB writes `Date` as UTC TEXT), so the input is always a
  /// `YYYY-MM-DD` day label. Parsing the components through `Calendar.utc`
  /// yields the same UTC-midnight `Date` the conversion service's UTC-keyed
  /// `ISO8601DateFormatter` would produce — preserving the per-day
  /// rate-cache equivalence — without an `ISO8601DateFormatter` (a
  /// reference type that would force an `@unchecked Sendable` wrapper to be
  /// hoisted to a shared `static let`). Pure value arithmetic, so it is
  /// trivially `Sendable` and allocates no formatter per row.
  ///
  /// Returns `nil` for malformed day strings; callers log and skip the
  /// row rather than silently swallowing.
  static func parseDayString(_ day: String) -> Date? {
    let fields = day.split(separator: "-", omittingEmptySubsequences: false)
    guard fields.count == 3,
      let year = Int(fields[0]), let month = Int(fields[1]), let dayOfMonth = Int(fields[2])
    else { return nil }
    return Calendar.utc.date(
      from: DateComponents(year: year, month: month, day: dayOfMonth))
  }

  /// Compute the financial-month key (`YYYYMM`) for `date`, respecting
  /// the user's configured `monthEnd` cut-off.
  ///
  /// Thin façade over `FinancialMonth.key(for:monthEnd:)` — kept on
  /// the repository so the call sites read alongside the rest of the
  /// per-aggregation helpers without having to import the shared
  /// helper directly.
  static func financialMonth(for date: Date, monthEnd: Int) -> String {
    FinancialMonth.key(for: date, monthEnd: monthEnd)
  }

  /// Build an `InstrumentAmount` in `target` from a SQL-summed storage
  /// quantity, converting on `day` when the source instrument differs.
  /// Same-instrument legs short-circuit and skip the conversion service.
  ///
  /// The signature takes `(storageValue, instrument)` rather than a
  /// `TransactionLeg` because rows arrive as already-summed
  /// `(storageValue, instrumentId)` tuples from the GROUP BY — no leg
  /// is available to project from.
  ///
  /// `.knownZero` source instruments (`.unpriced` / `.spam` crypto
  /// registrations) fold to `.zero(target)` rather than failing the
  /// row, so income/expense, breakdown and category aggregations omit
  /// the unpriced contribution but still render the rest of the day.
  /// Issue #790. A real provider error still throws.
  @concurrent
  static func convertedQuantity(
    storageValue: Int64,
    instrument: Instrument,
    to target: Instrument,
    on day: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    let amount = InstrumentAmount(storageValue: storageValue, instrument: instrument)
    if instrument.id == target.id {
      return amount
    }
    let result = try await conversionService.convertResult(amount, to: target, on: day)
    switch result {
    case .value(let converted): return converted
    case .knownZero: return .zero(instrument: target)
    }
  }
}
