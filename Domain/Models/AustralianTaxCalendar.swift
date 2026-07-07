import Foundation

enum AustralianTaxCalendar {
  static let timeZone: TimeZone = {
    guard let timeZone = TimeZone(identifier: "Australia/Sydney") else {
      fatalError("Australia/Sydney timezone must be available")
    }
    return timeZone
  }()

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = timeZone
    return calendar
  }
}
