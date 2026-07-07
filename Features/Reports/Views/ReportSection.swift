import Foundation

enum ReportSection: String, CaseIterable, Identifiable {
  case incomeAndExpenses = "Income & Expenses"
  case capitalGains = "Capital Gains"

  var id: String { rawValue }
}
