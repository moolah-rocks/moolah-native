import Foundation
import MCP

/// Closed operation names keep limit errors useful without echoing arguments or financial data.
public enum MCPQueryOperation: String, Sendable {
  case readQuery = "read_query"
  case balances
  case earmarks
  case summary
  case summaryFlows = "summary_flows"
  case summaryGroups = "summary_groups"
  case netWorth = "net_worth"
  case transactionDetails = "transaction_details"

  static func responseOperation(toolName: String) -> Self {
    switch toolName {
    case "moolah_get_balances": .balances
    case "moolah_list_earmarks": .earmarks
    case "moolah_get_summary": .summary
    case "moolah_find_transactions", "moolah_get_transaction": .transactionDetails
    default: .readQuery
    }
  }
}

/// Limits describe either computation or returned data, independently of the HTTP envelope cap.
public enum MCPLimitUnit: String, Sendable {
  case transactionLegs = "transaction_legs"
  case calculationGroups = "calculation_groups"
  case accounts
  case bytes
}

/// Safe detailed failure assembled solely from closed names and configured numeric limits.
public enum MCPQueryLimit: Error, Sendable, Equatable {
  case calculation(operation: MCPQueryOperation, unit: MCPLimitUnit, maximum: Int)
  case response(operation: MCPQueryOperation, unit: MCPLimitUnit, maximum: Int)

  var code: MCPAccessFailure {
    switch self {
    case .calculation: .calculationLimit
    case .response: .responseTooLarge
    }
  }

  func result() -> CallTool.Result {
    switch self {
    case let .calculation(operation, unit, maximum):
      result(operation: operation, unit: unit, maximum: maximum, isResponse: false)
    case let .response(operation, unit, maximum):
      result(operation: operation, unit: unit, maximum: maximum, isResponse: true)
    }
  }
}

extension MCPQueryLimit {
  private func result(
    operation: MCPQueryOperation,
    unit: MCPLimitUnit,
    maximum: Int,
    isResponse: Bool
  ) -> CallTool.Result {
    let action = nextStep(operation: operation, isResponse: isResponse)
    let kind = isResponse ? "response" : "calculation"
    let displayLimit = maximum.formatted(.number.locale(Locale(identifier: "en_US")))
    let operationLabel = operation.rawValue.replacingOccurrences(of: "_", with: " ")
    let unitLabel = unit.rawValue.replacingOccurrences(of: "_", with: " ")
    let message =
      "The \(operationLabel) \(kind) exceeds the limit of \(displayLimit) \(unitLabel)."
    return .init(
      content: [
        .text(text: "\(code.rawValue): \(message) \(action)", annotations: nil, _meta: nil)
      ],
      structuredContent: .object([
        "error": .object([
          "code": .string(code.rawValue), "message": .string(message),
          "operation": .string(operation.rawValue), "unit": .string(unit.rawValue),
          "limit": .int(maximum), "next_step": .string(action),
        ])
      ]),
      isError: true
    )
  }
}

extension MCPQueryLimit {
  private func nextStep(operation: MCPQueryOperation, isResponse: Bool) -> String {
    switch operation {
    case .netWorth:
      "Retry moolah_get_summary with include_net_worth: false. Read balances separately with moolah_get_balances and follow next_cursor."
    case .balances where isResponse:
      "Retry moolah_get_balances with mode: account_totals or a smaller limit. Restart without a cursor when changing options."
    case .balances:
      "Restart moolah_get_balances without a cursor using a smaller limit. If one account exceeds this limit, view its balance in Moolah."
    case .earmarks:
      "Restart moolah_list_earmarks without a cursor using a smaller limit. If one earmark exceeds this limit, view it in Moolah."
    case .summaryFlows:
      "Retry moolah_get_summary with a shorter date range and include_net_worth: false. Read balances separately with moolah_get_balances and follow next_cursor."
    case .summaryGroups, .summary:
      "Retry moolah_get_summary with group_by: none or a shorter date range."
    case .transactionDetails:
      "Retry moolah_find_transactions with a smaller limit. If one transaction exceeds the limit, view it in Moolah."
    case .readQuery:
      "Restart the query without a cursor using a smaller limit or narrower filters."
    }
  }
}
