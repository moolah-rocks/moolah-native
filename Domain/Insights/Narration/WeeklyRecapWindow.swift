import Foundation

/// Pure ISO-week gate: determines whether the weekly recap should be shown
/// on this open.
///
/// The decision is stateless and date-injected so it is fully testable
/// without mocking a clock. The caller supplies `now` and `lastShown` — this
/// type never reads `Date()` internally (issue #1042).
enum WeeklyRecapWindow {

  /// Returns `true` when the recap should be shown.
  ///
  /// Rules:
  /// - `lastShown == nil` → never shown before → show.
  /// - `now` and `lastShown` are in different ISO `(yearForWeekOfYear, weekOfYear)`
  ///   tuples → a new week has started → show.
  /// - Same ISO week → already shown this week → hide.
  ///
  /// - Parameters:
  ///   - now: The current date. Must be provided by the caller — never call
  ///     `Date()` inside this function.
  ///   - lastShown: The date when the recap was last presented, or `nil` if
  ///     it has never been shown.
  ///   - calendar: The calendar used to extract ISO week components. Pass
  ///     `Calendar(identifier: .iso8601)` for correct Monday-anchored weeks.
  static func shouldShow(now: Date, lastShown: Date?, calendar: Calendar) -> Bool {
    guard let lastShown else { return true }
    let components: Set<Calendar.Component> = [.yearForWeekOfYear, .weekOfYear]
    let nowComponents = calendar.dateComponents(components, from: now)
    let lastComponents = calendar.dateComponents(components, from: lastShown)
    return nowComponents.yearForWeekOfYear != lastComponents.yearForWeekOfYear
      || nowComponents.weekOfYear != lastComponents.weekOfYear
  }
}
