import Foundation
import Testing

@testable import Moolah
@testable import MoolahMCP

struct MCPFinancialFailureTests {
  @Test
  func invalidConversionResultsReturnQueryFailureWithoutFinancialData() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPTestSecrets())
    let profileID = UUID()
    let credential = try await store.create(
      label: "Fixture",
      profileIDs: [profileID],
      scopes: [.accounts]
    )
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [invalidConversionTool()]
    )
    let body: [String: MCPToolValue] = [
      "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
      "params": .object([
        "name": .string(MCPToolDefinition.balances.rawValue),
        "arguments": .object(["profile_id": .string(profileID.uuidString)]),
      ]),
    ]
    let response = try await endpoint.respond(
      .init(
        method: "POST",
        headers: [
          "Authorization": "Bearer \(credential.token)", "Content-Type": "application/json",
          "Accept": "application/json",
          "MCP-Protocol-Version": "2025-11-25",
        ],
        body: JSONEncoder().encode(body),
        path: "/mcp"
      )
    )
    let data = try #require(response.bodyData)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    let structured = try #require(result["structuredContent"] as? [String: Any])
    #expect(result["isError"] as? Bool == true)
    let error = try #require(structured["error"] as? [String: Any])
    #expect(error["code"] as? String == "QUERY_FAILED")
    #expect(structured["value"] == nil)
  }
  private func invalidConversionTool() -> MCPAuthorizedTool {
    let schema = MCPToolSchemas.schema(for: .balances)
    return MCPAuthorizedTool(schema: schema, scope: .accounts) { _ in
      let calculation = ReadFinancialCalculationService(
        conversion: FakeConversionService { request, _ in
          .success(.value(InstrumentAmount(quantity: request.quantity, instrument: request.from)))
        }
      )
      _ = try await calculation.value(
        [
          ReadDatedAmount(
            amount: InstrumentAmount(quantity: 42, instrument: .USD),
            date: Date(timeIntervalSince1970: 1_700_000_000)
          )
        ],
        target: .AUD
      )
      throw ReadCalculationError.invalidResult
    }
  }

}
