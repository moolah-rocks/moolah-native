import Foundation

extension TimeZone {
  /// The UTC time zone, resolved once.
  ///
  /// `TimeZone(identifier: "UTC")` is documented never to return nil for the
  /// canonical `"UTC"` identifier; `TimeZone.gmt` is a non-optional zero-offset
  /// zone, so the constant resolves without a force-unwrap. Both fallbacks are
  /// still UTC — there is deliberately no `.current` backstop, which would
  /// silently produce wrong calendar-unit values in any non-UTC zone.
  static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .gmt
}

extension Calendar {
  /// The canonical calendar for reading and writing **timezoneless**
  /// calendar-unit values — a named month (`YYYYMM`), a calendar day
  /// (`YYYY-MM-DD`), or any value whose identity is "April 2026", *not* an
  /// instant on the timeline.
  ///
  /// Such values round-trip correctly only when the **same** fixed calendar
  /// is used to write and to read them. `Calendar.current` reads in the
  /// device's local zone, so a `Date` written at UTC midnight is shifted into
  /// the previous day — and thus a different month — in any UTC-negative
  /// zone. Routing every timezoneless parse/format/component-read through
  /// this one calendar keeps the result identical on every host.
  ///
  /// - `timeZone` is pinned to UTC (which observes no DST, so day arithmetic
  ///   is unambiguous).
  /// - `locale` is `en_US_POSIX` so a device configured with a non-Gregorian
  ///   calendar, a different `firstWeekday`, or localized symbols cannot
  ///   change how a label is parsed or how components are derived.
  ///
  /// `Calendar` is a `Sendable` value type, so this shared constant carries
  /// no concurrency caveats. Use `Calendar.current` only for values that are
  /// *meant* to follow the user's local zone (e.g. "is this transaction
  /// today?"). See `guides/DATE_TIME_GUIDE.md`.
  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .utc
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }()
}
