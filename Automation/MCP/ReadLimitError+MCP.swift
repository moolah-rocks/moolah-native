import MoolahMCP

extension ReadLimitError {
  var mcpFailure: MCPQueryLimit {
    if operation == .transactionDetails {
      return .response(operation: mcpOperation, unit: mcpUnit, maximum: maximum)
    }
    return .calculation(operation: mcpOperation, unit: mcpUnit, maximum: maximum)
  }

  private var mcpOperation: MCPQueryOperation {
    switch operation {
    case .balances: .balances
    case .earmarks: .earmarks
    case .summaryFlows: .summaryFlows
    case .summaryGroups: .summaryGroups
    case .netWorth: .netWorth
    case .transactionDetails: .transactionDetails
    }
  }

  private var mcpUnit: MCPLimitUnit {
    switch unit {
    case .transactionLegs: .transactionLegs
    case .calculationGroups: .calculationGroups
    case .accounts: .accounts
    }
  }
}
