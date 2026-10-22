/// Calculation failures identify the operation and configured bound without retaining query data.
struct ReadLimitError: Error, Sendable, Equatable {
  let operation: ReadLimitOperation
  let unit: ReadLimitUnit
  let maximum: Int
}

/// Domain operation names are independent of the local automation transport.
enum ReadLimitOperation: String, Sendable {
  case balances
  case earmarks
  case summaryFlows = "summary_flows"
  case summaryGroups = "summary_groups"
  case netWorth = "net_worth"
  case transactionDetails = "transaction_details"
}

/// Transaction details bound returned raw legs; other units bound calculation work or memory.
enum ReadLimitUnit: String, Sendable {
  case transactionLegs = "transaction_legs"
  case calculationGroups = "calculation_groups"
  case accounts
}
