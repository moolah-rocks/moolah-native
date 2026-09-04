import Foundation

/// Import-time windows offered by Recently Added. The lower bound is pinned
/// when selected so SwiftUI view updates do not continuously restart the
/// transaction observation; the future upper bound admits imports that land
/// while the view remains open.
enum RecentlyAddedWindow: String, CaseIterable {
  case last24Hours
  case last3Days
  case lastWeek
  case last2Weeks
  case lastMonth
  case all

  var label: String {
    switch self {
    case .last24Hours: return "Last 24 hours"
    case .last3Days: return "Last 3 days"
    case .lastWeek: return "Last week"
    case .last2Weeks: return "Last 2 weeks"
    case .lastMonth: return "Last month"
    case .all: return "All"
    }
  }

  func importedAtRange(now: Date) -> ClosedRange<Date> {
    let day: TimeInterval = 86_400
    switch self {
    case .last24Hours: return now.addingTimeInterval(-day)...Date.distantFuture
    case .last3Days: return now.addingTimeInterval(-3 * day)...Date.distantFuture
    case .lastWeek: return now.addingTimeInterval(-7 * day)...Date.distantFuture
    case .last2Weeks: return now.addingTimeInterval(-14 * day)...Date.distantFuture
    case .lastMonth: return now.addingTimeInterval(-30 * day)...Date.distantFuture
    case .all: return Date.distantPast...Date.distantFuture
    }
  }
}

extension RecentlyAddedWindow: Identifiable {
  var id: String { rawValue }
}
