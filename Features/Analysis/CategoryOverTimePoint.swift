import Foundation

/// A single month's point in a root category's expense-over-time series,
/// produced by `AnalysisStore.buildCategoriesOverTime`.
struct CategoryOverTimePoint: Sendable {
  let month: String
  let monthDate: Date
  let actualAmount: Decimal
  let percentage: Double
  /// True when any source row for this point's month failed to price
  /// (prices still loading), so the amount may be incomplete. See #1077.
  let isUnavailable: Bool

  init(
    month: String,
    monthDate: Date,
    actualAmount: Decimal,
    percentage: Double,
    isUnavailable: Bool = false
  ) {
    self.month = month
    self.monthDate = monthDate
    self.actualAmount = actualAmount
    self.percentage = percentage
    self.isUnavailable = isUnavailable
  }
}

extension CategoryOverTimePoint: Identifiable {
  var id: String { month }
}

/// A root category's full expense-over-time series across all months,
/// produced by `AnalysisStore.buildCategoriesOverTime`.
struct CategoryOverTimeEntry: Sendable {
  let categoryId: UUID?
  let points: [CategoryOverTimePoint]
  let totalAmount: Decimal
}

extension CategoryOverTimeEntry: Identifiable {
  var id: String { categoryId?.uuidString ?? "uncategorized" }
}
