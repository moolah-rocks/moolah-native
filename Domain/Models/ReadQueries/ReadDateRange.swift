import Foundation

/// Inclusive civil-day inputs converted once into a half-open interval in an explicit zone.
struct ReadDateRange: Sendable {
  let interval: Range<Date>
  let timeZone: TimeZone

  init(
    interval: Range<Date>,
    timeZone: TimeZone,
    horizon: ReadDateHorizon = .transactions
  ) throws {
    try Self.validate(interval: interval, timeZone: timeZone, horizon: horizon)
    self.interval = interval
    self.timeZone = timeZone
  }

  init(
    from: String,
    through: String,
    timeZone: TimeZone,
    horizon: ReadDateHorizon = .transactions
  ) throws {
    var calendar = Calendar.utc
    calendar.timeZone = timeZone
    let lower = try Self.date(from, calendar: calendar)
    let last = try Self.date(through, calendar: calendar)
    guard lower <= last,
      let upper = calendar.date(
        byAdding: .day,
        value: 1,
        to: last
      )
    else {
      throw ReadQueryError.invalidFilter
    }
    try self.init(interval: lower..<upper, timeZone: timeZone, horizon: horizon)
  }
}

extension ReadDateRange {
  func validate(horizon: ReadDateHorizon) throws {
    try Self.validate(interval: interval, timeZone: timeZone, horizon: horizon)
  }

  private static func validate(interval: Range<Date>, timeZone: TimeZone, horizon: ReadDateHorizon)
    throws
  {
    var calendar = Calendar.utc
    calendar.timeZone = timeZone
    let years = horizon == .summary ? 10 : 1
    guard interval.lowerBound < interval.upperBound,
      let maximum = calendar.date(byAdding: .year, value: years, to: interval.lowerBound),
      interval.upperBound <= maximum
    else { throw ReadQueryError.invalidFilter }
  }

  private static func date(
    _ value: String,
    calendar: Calendar
  ) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard value.utf8.count == 10, let date = formatter.date(from: value),
      formatter.string(from: date) == value
    else { throw ReadQueryError.invalidFilter }
    return calendar.startOfDay(for: date)
  }
}

/// A tool chooses the horizon; a client cannot widen transaction-search limits.
enum ReadDateHorizon: Sendable {
  case transactions
  case summary
}
