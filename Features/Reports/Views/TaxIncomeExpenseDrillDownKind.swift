enum TaxIncomeExpenseDrillDownKind: Hashable {
  case income
  case deductions

  var transactionType: TransactionType {
    switch self {
    case .income:
      return .income
    case .deductions:
      return .expense
    }
  }

  var title: String {
    switch self {
    case .income:
      return "Taxable income"
    case .deductions:
      return "Deductions"
    }
  }

  var amountStyle: TransactionListAmountStyle {
    switch self {
    case .income:
      return .standard
    case .deductions:
      return .deduction
    }
  }
}
