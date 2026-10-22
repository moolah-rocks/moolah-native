import Testing

@testable import MoolahMCP

struct MCPQueryLimitTests {
  @Test
  func netWorthCalculationLimitExplainsHowToKeepTheSpendingQuery() throws {
    let failure = MCPQueryLimit.calculation(
      operation: .netWorth,
      unit: .transactionLegs,
      maximum: 250_000
    )
    let error = try #require(failure.result().structuredContent?.objectValue?["error"]?.objectValue)
    #expect(error["code"]?.stringValue == "CALCULATION_LIMIT_EXCEEDED")
    #expect(error["operation"]?.stringValue == "net_worth")
    #expect(error["limit"]?.intValue == 250_000)
    #expect(error["next_step"]?.stringValue?.contains("include_net_worth: false") == true)
  }

  @Test
  func oversizedBalanceResponseSuggestsCompactTotals() throws {
    let failure = MCPQueryLimit.response(operation: .balances, unit: .bytes, maximum: 500_000)
    let error = try #require(failure.result().structuredContent?.objectValue?["error"]?.objectValue)
    #expect(error["code"]?.stringValue == "RESPONSE_TOO_LARGE")
    #expect(error["operation"]?.stringValue == "balances")
    #expect(error["unit"]?.stringValue == "bytes")
    #expect(error["next_step"]?.stringValue?.contains("account_totals") == true)
  }
}
