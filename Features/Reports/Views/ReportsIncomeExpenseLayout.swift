import Foundation

/// Pure layout policy for the Reports income/expense surface.
/// Kept out of SwiftUI so compact-scroll behaviour is unit-testable.
enum ReportsIncomeExpenseLayoutStep: Hashable {
  /// One parent vertical scroll owns the compact report flow.
  case singleVerticalScroll
  case income
  case expenses
}

enum ReportsIncomeExpenseLayout {
  /// iPhone compact Reports order: one scroll container, then Income, then Expenses.
  static let iOSPresentation: [ReportsIncomeExpenseLayoutStep] = [
    .singleVerticalScroll, .income, .expenses,
  ]
}
