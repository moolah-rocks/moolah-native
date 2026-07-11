import Foundation

enum ReportSection: String, CaseIterable, Identifiable {
  case incomeAndExpenses = "Income & Expenses"
  case capitalGains = "Tax"

  var id: String { rawValue }
}
