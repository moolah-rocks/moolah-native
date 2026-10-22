import Foundation
import MoolahMCP

/// The V1 catalogue is explicit and read-only; write automation is never reflected into it.
enum MCPToolDefinition: String, CaseIterable, Sendable {
  case profiles = "moolah_list_profiles"
  case status = "moolah_get_status"
  case accounts = "moolah_list_accounts"
  case balances = "moolah_get_balances"
  case transactions = "moolah_find_transactions"
  case transaction = "moolah_get_transaction"
  case categories = "moolah_list_categories"
  case earmarks = "moolah_list_earmarks"
  case summary = "moolah_get_summary"

  var scope: MCPReadScope {
    switch self {
    case .profiles, .status: .profiles
    case .accounts, .balances: .accounts
    case .transactions, .transaction: .transactions
    case .categories: .categories
    case .earmarks: .earmarks
    case .summary: .summaries
    }
  }

  var argumentKeys: Set<String> {
    var result: Set<String> = ["profile_id", "time_zone"]
    switch self {
    case .profiles: return ["time_zone"]
    case .status: break
    case .accounts: result.formUnion(["include_hidden", "limit", "cursor"])
    case .balances: result.formUnion(["account_ids", "as_of", "reporting_instrument"])
    case .transactions:
      result.formUnion([
        "from_date", "to_date", "account_ids", "category_ids", "payee_query", "scheduled",
        "include_notes", "limit", "cursor",
      ])
    case .transaction: result.formUnion(["transaction_id", "include_notes"])
    case .categories, .earmarks: result.formUnion(["limit", "cursor"])
    case .summary:
      result.formUnion([
        "from_date", "to_date", "group_by", "reporting_instrument", "include_net_worth",
      ])
    }
    return result
  }
}
