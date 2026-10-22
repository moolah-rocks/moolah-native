import Foundation
import MoolahMCP
import Testing

@testable import Moolah

@MainActor
struct MCPMonthlySummaryTests {
  @Test
  func monthlySummaryReturnsNamesParentsAndTheRequestedTimezone() async throws {
    let fixture = try await MCPToolRegistryTests().fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    let (parent, child) = try await seedHousehold(fixture)
    var arguments = fixture.arguments
    arguments["from_date"] = .string("2020-01-01")
    arguments["to_date"] = .string("2029-12-31")
    arguments["time_zone"] = .string("America/Los_Angeles")
    arguments["group_by"] = .string("category_month")
    let result = try await fixture.registry.call(
      .summary,
      context: fixture.context,
      arguments: arguments
    )
    let object = try MCPToolRegistryTests().object(result)
    #expect(
      (object["metadata"] as? [String: Any])?["time_zone"] as? String == "America/Los_Angeles"
    )
    let item = try #require((object["items"] as? [[String: Any]])?.first)
    let groups = try #require(item["groups"] as? [[String: Any]])
    #expect(groups.count == 2)
    #expect(groups.allSatisfy { $0["month"] as? String == "2026-01" })
    #expect(
      Set(groups.compactMap { $0["category_name"] as? String }) == ["Household", "Groceries"]
    )
    #expect(
      groups.first { $0["category_id"] as? String == child.id.uuidString }?["parent_category_id"]
        as? String == parent.id.uuidString
    )
    await #expect(throws: MCPAccessFailure.invalidFilter) {
      try await fixture.registry.call(
        .transactions,
        context: fixture.context,
        arguments: arguments.filter { !["group_by"].contains($0.key) }
      )
    }
  }
  private func seedHousehold(_ fixture: MCPToolRegistryTests.Fixture) async throws -> (
    Moolah.Category, Moolah.Category
  ) {
    let parent = try await fixture.session.backend.categories.create(Category(name: "Household"))
    let child = try await fixture.session.backend.categories.create(
      Category(name: "Groceries", parentId: parent.id)
    )
    let date = try #require(ISO8601DateFormatter().date(from: "2026-02-01T01:00:00Z"))
    let account = try await fixture.session.backend.accounts.create(
      Account(name: "Fixture", type: .bank, instrument: fixture.profile.instrument)
    )
    _ = try await fixture.session.backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: fixture.profile.instrument,
            quantity: -7,
            type: .expense,
            categoryId: child.id
          )
        ]
      )
    )
    return (parent, child)
  }

}
