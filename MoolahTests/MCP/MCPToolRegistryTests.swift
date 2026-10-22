import Foundation
import MoolahMCP
import Testing

@testable import Moolah

@MainActor
struct MCPToolRegistryTests {
  struct Fixture {
    let manager: SessionManager
    let profile: Profile
    let session: ProfileSession
    let grants: MCPGrantStore
    let context: MCPAuthorizationContext
    let registry: MCPToolRegistry

    var arguments: [String: MCPToolValue] { ["profile_id": .string(profile.id.uuidString)] }
  }

  func fixture(scopes: Set<MCPReadScope> = MCPReadScope.standard) async throws -> Fixture {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Tool fixture")
    let index = containers.profileIndexRepositoryForTesting
    try await index.upsert(profile)
    let manager = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: index
    )
    let session = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let grants = try await MCPGrantStore.open(persistence: MCPTestSecrets())
    let credential = try await grants.create(
      label: "Fixture",
      profileIDs: [profile.id],
      scopes: scopes
    )
    let context = try #require(try await grants.authenticate(header: "Bearer \(credential.token)"))
    return Fixture(
      manager: manager,
      profile: profile,
      session: session,
      grants: grants,
      context: context,
      registry: try MCPToolRegistry(
        service: MoolahReadQueryService(sessions: manager),
        grants: grants,
        currentTimeZone: { .utc }
      )
    )
  }

  func object(_ result: MCPToolResult) throws -> [String: Any] {
    let value = try #require(result.structuredContent)
    return try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
    )
  }

  @Test
  func allNineToolsUseTheIsolatedProfileWithoutChangingVisibleFilters() async throws {
    let fixture = try await fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    let filter = TransactionFilter(payee: "Visible filter")
    fixture.session.transactionStore.setCurrentFilter(filter)
    let account = Account(name: "Fixture", type: .bank, instrument: fixture.profile.instrument)
    _ = try await fixture.session.backend.accounts.create(account)
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_767_312_000),
      notes: "Private note",
      legs: [
        TransactionLeg(
          accountId: account.id,
          instrument: fixture.profile.instrument,
          quantity: -10,
          type: .expense
        )
      ]
    )
    _ = try await fixture.session.backend.transactions.create(transaction)
    #expect(fixture.registry.tools.count == 9)
    for tool in MCPToolDefinition.allCases {
      var arguments = tool == .profiles ? [:] : fixture.arguments
      if tool == .transactions || tool == .summary {
        arguments["from_date"] = .string("2026-01-01")
        arguments["to_date"] = .string("2026-01-31")
      }
      if tool == .transaction { arguments["transaction_id"] = .string(transaction.id.uuidString) }
      let result = try await fixture.registry.call(
        tool,
        context: fixture.context,
        arguments: arguments
      )
      let response = try object(result)
      #expect(response["items"] is [Any])
      let wire = try JSONEncoder().encode(result.structuredContent)
      #expect(!(String(bytes: wire, encoding: .utf8) ?? "").contains("Private note"))
    }
    #expect(fixture.session.transactionStore.currentFilter == filter)
  }

  @Test
  func permissionsAreCheckedBeforeResolvingProfilesAndNotes() async throws {
    let fixture = try await fixture(scopes: [.accounts, .transactions])
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    await #expect(throws: MCPAccessFailure.accessDenied) {
      try await fixture.registry.call(.summary, context: fixture.context, arguments: [:])
    }
    let missing = UUID()
    await #expect(throws: MCPAccessFailure.accessDenied) {
      try await fixture.registry.call(
        .accounts,
        context: fixture.context,
        arguments: ["profile_id": .string(missing.uuidString)]
      )
    }
    var arguments = fixture.arguments
    arguments["transaction_id"] = .string(UUID().uuidString)
    arguments["include_notes"] = .bool(true)
    await #expect(throws: MCPAccessFailure.accessDenied) {
      try await fixture.registry.call(.transaction, context: fixture.context, arguments: arguments)
    }
    #expect(fixture.manager.sessions[missing] == nil)
    try await fixture.grants.revoke(id: fixture.context.grantID)
    await #expect(throws: MCPAccessFailure.accessDenied) {
      try await fixture.registry.call(
        .accounts,
        context: fixture.context,
        arguments: fixture.arguments
      )
    }
  }
}

extension MCPToolRegistryTests {
  @Test
  func paginationBindsFiltersAndExpiresAfterWrites() async throws {
    let fixture = try await fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    for name in ["First", "Second"] {
      _ = try await fixture.session.backend.accounts.create(
        Account(name: name, type: .bank, instrument: fixture.profile.instrument)
      )
    }
    var arguments = fixture.arguments
    arguments["limit"] = .int(1)
    let first = try object(
      await fixture.registry.call(.accounts, context: fixture.context, arguments: arguments)
    )
    let cursor = try #require(first["next_cursor"] as? String)
    #expect(first["has_more"] as? Bool == true)
    arguments["cursor"] = .string(cursor)
    let second = try object(
      await fixture.registry.call(.accounts, context: fixture.context, arguments: arguments)
    )
    #expect(second["has_more"] as? Bool == false)
    arguments["include_hidden"] = .bool(true)
    await #expect(throws: MCPAccessFailure.cursorExpired) {
      try await fixture.registry.call(.accounts, context: fixture.context, arguments: arguments)
    }
    arguments.removeValue(forKey: "include_hidden")
    _ = try await fixture.session.backend.accounts.create(
      Account(name: "New", type: .bank, instrument: fixture.profile.instrument)
    )
    await #expect(throws: MCPAccessFailure.cursorExpired) {
      try await fixture.registry.call(.accounts, context: fixture.context, arguments: arguments)
    }
  }

  @Test
  func unsupportedHistoricalBalancesAndInvalidArgumentsFailExplicitly() async throws {
    let fixture = try await fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    var arguments = fixture.arguments
    arguments["as_of"] = .string("2026-01-01")
    await #expect(throws: MCPAccessFailure.unsupported) {
      try await fixture.registry.call(.balances, context: fixture.context, arguments: arguments)
    }
    arguments = fixture.arguments
    arguments["limit"] = .int(501)
    await #expect(throws: MCPAccessFailure.invalidFilter) {
      try await fixture.registry.call(.accounts, context: fixture.context, arguments: arguments)
    }
    arguments = fixture.arguments
    arguments["extra"] = .string("unexpected")
    await #expect(throws: MCPAccessFailure.invalidFilter) {
      try await fixture.registry.call(.status, context: fixture.context, arguments: arguments)
    }
  }
}

extension MCPToolRegistryTests {
  @Test
  func summaryNetWorthRequiresAnExplicitRequest() async throws {
    let fixture = try await fixture()
    defer { fixture.manager.removeSession(for: fixture.profile.id) }
    var arguments = fixture.arguments
    arguments["from_date"] = .string("2026-01-01")
    arguments["to_date"] = .string("2026-01-01")
    let ordinary = try object(
      await fixture.registry.call(.summary, context: fixture.context, arguments: arguments)
    )
    let ordinaryItem = try #require((ordinary["items"] as? [[String: Any]])?.first)
    #expect(ordinaryItem["net_worth_included"] as? Bool == false)
    #expect(ordinaryItem["current_net_worth"] == nil)
    arguments["include_net_worth"] = .bool(true)
    let requested = try object(
      await fixture.registry.call(.summary, context: fixture.context, arguments: arguments)
    )
    let requestedItem = try #require((requested["items"] as? [[String: Any]])?.first)
    #expect(requestedItem["net_worth_included"] as? Bool == true)
    #expect(requestedItem["current_net_worth"] is [String: Any])
  }
}
