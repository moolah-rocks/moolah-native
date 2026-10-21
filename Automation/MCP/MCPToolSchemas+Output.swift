import MoolahMCP

extension MCPToolSchemas {
  static func output(_ tool: MCPToolDefinition) -> MCPToolValue {
    if tool == .profiles {
      return object(
        [
          "queried_at": instant, "time_zone": string, "sync_state": string,
          "items": array(profile, maximum: 500),
        ],
        required: ["queried_at", "time_zone", "sync_state", "items"]
      )
    }
    let item: MCPToolValue
    switch tool {
    case .profiles, .status: item = profile
    case .accounts: item = account
    case .balances: item = balance
    case .transactions, .transaction: item = transaction
    case .categories: item = category
    case .earmarks: item = earmark
    case .summary: item = summary
    }
    return object(
      [
        "metadata": metadata, "items": array(item),
        "next_cursor": nullable(string), "has_more": boolean,
      ],
      required: ["metadata", "items", "has_more"]
    )
  }

  private static var metadata: MCPToolValue {
    let properties = [
      "queried_at": instant, "profile_id": uuid, "time_zone": string,
      "local_revision": string, "consistency": string, "sync_state": string,
      "warnings": array(string),
    ]
    return object(properties, required: properties.keys.sorted())
  }

  private static var instrument: MCPToolValue {
    object(
      [
        "id": string, "kind": string,
        "display_decimals": .object(["type": .string("integer")]),
        "storage_scale": .object(["type": .string("integer"), "const": .int(8)]),
      ],
      required: ["id", "kind", "display_decimals", "storage_scale"]
    )
  }

  private static var quantity: MCPToolValue {
    object(
      [
        "quantity": .object([
          "type": .string("string"),
          "description": .string(
            "Exact signed base-10 decimal string. Stored amounts use eight decimal places; calculated conversions preserve decimal precision."
          ),
        ]),
        "instrument": instrument,
      ],
      required: ["quantity", "instrument"]
    )
  }

  private static var profile: MCPToolValue {
    object(
      [
        "id": uuid, "label": nullable(string), "base_instrument": nullable(instrument),
        "readiness": string, "sync_state": string,
      ],
      required: ["id", "readiness", "sync_state"]
    )
  }

  private static var account: MCPToolValue {
    object(
      [
        "id": uuid, "name": string, "type": string, "primary_instrument": instrument,
        "is_hidden": boolean,
      ],
      required: ["id", "name", "type", "primary_instrument", "is_hidden"]
    )
  }

  private static var category: MCPToolValue {
    object(["id": uuid, "name": string, "parent_id": nullable(uuid)], required: ["id", "name"])
  }

  private static var earmark: MCPToolValue {
    object(
      [
        "id": uuid, "name": string, "is_hidden": boolean, "primary_instrument": instrument,
        "target": nullable(quantity), "positions": array(quantity),
      ],
      required: ["id", "name", "is_hidden", "primary_instrument", "positions"]
    )
  }

  private static var transaction: MCPToolValue {
    let leg = object(
      [
        "id": uuid, "account_id": nullable(uuid), "amount": quantity, "type": string,
        "category_id": nullable(uuid), "earmark_id": nullable(uuid), "matches_filters": boolean,
      ],
      required: ["id", "amount", "type", "matches_filters"]
    )
    return object(
      [
        "id": uuid, "date": instant, "payee": nullable(string), "notes": nullable(string),
        "scheduled": boolean, "legs": array(leg),
      ],
      required: ["id", "date", "scheduled", "legs"]
    )
  }

  private static var valuation: MCPToolValue {
    let properties = [
      "value": nullable(quantity), "reporting_instrument": instrument, "status": string,
      "requested_at": nullable(instant), "oldest_price_at": nullable(instant),
      "provenance": string, "error_code": nullable(string),
    ]
    return object(properties, required: properties.keys.sorted())
  }

  private static var balance: MCPToolValue {
    object(
      [
        "account_id": uuid,
        "positions": array(
          object(["native": quantity, "valuation": valuation], required: ["native", "valuation"])
        ),
        "total": valuation,
      ],
      required: ["account_id", "positions", "total"]
    )
  }

  private static var summary: MCPToolValue {
    let group = object(
      [
        "category_id": nullable(uuid), "income": array(quantity), "spending": array(quantity),
        "reporting_income": valuation, "reporting_spending": valuation,
      ],
      required: ["income", "spending", "reporting_income", "reporting_spending"]
    )
    let properties = [
      "semantics": string, "reporting_instrument": instrument,
      "income": array(quantity), "spending": array(quantity),
      "reporting_income": valuation, "reporting_spending": valuation,
      "current_net_worth": valuation, "groups": array(group, maximum: 500),
    ]
    return object(properties, required: properties.keys.sorted())
  }
}
