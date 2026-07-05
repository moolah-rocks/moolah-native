import Foundation

/// Persistence for the Reports screen's last-used date range. Stored in local
/// `UserDefaults` (the environment-scoped `.moolahShared` suite) only — never
/// synced across devices.
///
/// Relative presets (e.g. `.last3Months`) are persisted as the preset itself
/// and re-resolve against the current date on every launch, so "Last 3 months"
/// always means the three months ending today. Only `.custom` carries explicit
/// endpoints, stored as `timeIntervalSinceReferenceDate` doubles.
///
/// The selected range is stored via a **stable token** (`token(for:)`), not its
/// `rawValue`: `DateRange`'s raw values are the picker's user-facing display
/// strings, so persisting them would silently drop a saved preference the
/// moment that copy is edited. Tokens are an independent, permanent contract —
/// never change or reuse one.
enum ReportsPeriodStorage {
  static let rangeKey = "reportsDateRange"
  static let customFromKey = "reportsCustomFrom"
  static let customToKey = "reportsCustomTo"

  /// Initial values for the Reports view's date-range state, derived from the
  /// persisted preference. `resolvedFrom`/`resolvedTo` drive the data load and
  /// are seeded so the first render shows the restored window with no flash of
  /// the default range and no redundant reload.
  struct Seed: Equatable {
    let dateRange: DateRange
    let customFrom: Date
    let customTo: Date
    let resolvedFrom: Date
    let resolvedTo: Date
  }

  // MARK: - Stable tokens

  /// Permanent persistence tokens, decoupled from `rawValue` / `displayName`
  /// (both user-facing copy). Never change or reuse a value. Completeness is
  /// guaranteed by `tokens_areStableAndRoundTrip`, which round-trips every case.
  private static let tokensByRange: [DateRange: String] = [
    .thisFinancialYear: "thisFinancialYear",
    .lastFinancialYear: "lastFinancialYear",
    .lastMonth: "lastMonth",
    .last3Months: "last3Months",
    .last6Months: "last6Months",
    .last9Months: "last9Months",
    .last12Months: "last12Months",
    .monthToDate: "monthToDate",
    .quarterToDate: "quarterToDate",
    .yearToDate: "yearToDate",
    .custom: "custom",
  ]

  /// Permanent persistence token for a range. The `rawValue` fallback is
  /// unreachable in practice — it only fires if a new case is added without a
  /// token, which the round-trip test catches.
  static func token(for range: DateRange) -> String {
    tokensByRange[range] ?? range.rawValue
  }

  /// Resolves a persisted token back to its range, or `nil` for an unknown /
  /// retired token (callers fall back to the default range).
  static func range(forToken token: String) -> DateRange? {
    tokensByRange.first { $0.value == token }?.key
  }

  // MARK: - Read

  /// Reads the seed from a defaults store. Defaults to `.moolahShared`, the
  /// environment-scoped suite used for the app's other persisted preferences.
  static func seed(from defaults: UserDefaults = .moolahShared, today: Date = Date()) -> Seed {
    seed(
      storedRangeToken: defaults.string(forKey: rangeKey),
      storedCustomFrom: defaults.object(forKey: customFromKey) as? Double,
      storedCustomTo: defaults.object(forKey: customToKey) as? Double,
      today: today)
  }

  /// Computes the seed from raw persisted values. Pure and injectable so the
  /// resolution can be tested without touching `UserDefaults` or the wall clock.
  static func seed(
    storedRangeToken: String?,
    storedCustomFrom: Double?,
    storedCustomTo: Double?,
    today: Date = Date()
  ) -> Seed {
    let range = storedRangeToken.flatMap { self.range(forToken: $0) } ?? .last12Months
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: today)

    let defaultCustomFrom = calendar.date(byAdding: .year, value: -1, to: today) ?? today
    let customFrom =
      storedCustomFrom.map(Date.init(timeIntervalSinceReferenceDate:)) ?? defaultCustomFrom
    let customTo = storedCustomTo.map(Date.init(timeIntervalSinceReferenceDate:)) ?? today

    let resolvedFrom = range == .custom ? customFrom : range.startDate(today: startOfToday)
    let resolvedTo = range == .custom ? customTo : range.endDate(today: startOfToday)

    return Seed(
      dateRange: range,
      customFrom: customFrom,
      customTo: customTo,
      resolvedFrom: resolvedFrom,
      resolvedTo: resolvedTo)
  }

  // MARK: - Write

  static func persist(range: DateRange, in defaults: UserDefaults = .moolahShared) {
    defaults.set(token(for: range), forKey: rangeKey)
  }

  static func persistCustomFrom(_ date: Date, in defaults: UserDefaults = .moolahShared) {
    defaults.set(date.timeIntervalSinceReferenceDate, forKey: customFromKey)
  }

  static func persistCustomTo(_ date: Date, in defaults: UserDefaults = .moolahShared) {
    defaults.set(date.timeIntervalSinceReferenceDate, forKey: customToKey)
  }
}
