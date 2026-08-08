import Foundation

// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
enum TransactionType: String, Codable, Sendable, CaseIterable, Hashable {
  case income
  case expense
  case transfer
  case openingBalance
  case trade

  /// Whether this transaction type can be manually created or edited by users.
  /// `.openingBalance` transactions are system-generated and cannot be modified.
  /// `.trade` transactions are user-editable; the bespoke trade UI ships in a
  /// subsequent task in this branch.
  var isUserEditable: Bool {
    self != .openingBalance
  }

  /// Display name for the transaction type
  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .openingBalance: return "Opening Balance"
    case .trade: return "Trade"
    }
  }

  /// Only types that users can select when creating/editing transactions
  static var userSelectableTypes: [TransactionType] {
    [.income, .expense, .transfer, .trade]
  }
}
