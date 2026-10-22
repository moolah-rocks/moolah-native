import Foundation
import MoolahMCP
import Testing

@testable import Moolah

@MainActor
struct MCPRegistryLimitsTests {
  @Test
  func oversizedBalanceResponseIdentifiesItsOperationAndByteLimit() async throws {
    let fixture = try await MCPToolRegistryTests().fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    _ = try await fixture.session.backend.accounts.create(
      Account(
        name: String(repeating: "x", count: 500_001),
        type: .bank,
        instrument: fixture.profile.instrument
      )
    )
    await #expect(
      throws: MCPQueryLimit.response(operation: .balances, unit: .bytes, maximum: 500_000)
    ) {
      try await fixture.registry.call(
        .balances,
        context: fixture.context,
        arguments: fixture.arguments
      )
    }
  }

  @Test
  func netWorthAccountLimitDoesNotBlockTheDefaultSummary() async throws {
    let fixture = try await MCPToolRegistryTests().fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    for index in 0..<501 {
      _ = try await fixture.session.backend.accounts.create(
        Account(name: "Fixture \(index)", type: .bank, instrument: fixture.profile.instrument)
      )
    }
    var arguments = fixture.arguments
    arguments["from_date"] = .string("2026-01-01")
    arguments["to_date"] = .string("2026-01-01")
    _ = try await fixture.registry.call(.summary, context: fixture.context, arguments: arguments)
    arguments["include_net_worth"] = .bool(true)
    await #expect(
      throws: MCPQueryLimit.calculation(operation: .netWorth, unit: .accounts, maximum: 500)
    ) {
      try await fixture.registry.call(.summary, context: fixture.context, arguments: arguments)
    }
  }
}
