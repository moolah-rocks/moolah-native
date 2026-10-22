import Foundation

/// Summary inputs distinguish optional lifetime positions from requested-period report flows.
struct ReadSummaryQuery: Sendable {
  let range: ReadDateRange
  let grouping: ReadSummaryGrouping
  let includeNetWorth: Bool
  let includeParentTotals: Bool
}

/// Month groups use Gregorian months in the requested timezone, independent of UTC price days.
enum ReadSummaryGrouping: String, Sendable {
  case none
  case category
  case month
  case categoryMonth = "category_month"

  var includesCategories: Bool { self == .category || self == .categoryMonth }
  var includesMonths: Bool { self == .month || self == .categoryMonth }
}
