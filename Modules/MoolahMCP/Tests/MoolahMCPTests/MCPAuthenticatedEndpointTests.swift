import Foundation
import MCP
import Synchronization
import Testing

@testable import MoolahMCP

struct MCPAuthenticatedEndpointTests {
  @Test
  func authenticatesDiscoveryAndFiltersTheCatalogueWithoutOpeningProfiles() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(
      label: "Fixture",
      profileIDs: [profile],
      scopes: [.accounts]
    )
    let calls = Mutex(0)
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [tool(scope: .accounts), tool(name: "moolah_transactions", scope: .transactions)]
    )
    let missing = try await endpoint.respond(request(method: "initialize"))
    #expect(missing.statusCode == 401)
    let listed = try await endpoint.respond(request(token: credential.token, method: "tools/list"))
    let result = try #require(try object(listed)["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["moolah_probe"])
    let annotations = try #require(tools.first?["annotations"] as? [String: Any])
    #expect(annotations["readOnlyHint"] as? Bool == true)
    let guarded = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [
        tool { _ in
          calls.withLock { $0 += 1 }
          return .init()
        }
      ]
    )
    let denied = try await guarded.respond(callRequest(token: credential.token, profile: UUID()))
    #expect(try errorCode(denied) == "ACCESS_DENIED")
    #expect(calls.withLock { $0 } == 0)
  }

  @Test
  func rejectsScopeDenialAndOversizedResultsWithSafeToolErrors() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(
      label: "Fixture",
      profileIDs: [profile],
      scopes: [.accounts]
    )
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [
        tool(scope: .transactions),
        tool(name: "moolah_large") { _ in
          .init(
            structuredContent: .object([
              "fixture": .string(String(repeating: "x", count: 1_048_576))
            ])
          )
        },
      ]
    )
    let denied = try await endpoint.respond(callRequest(token: credential.token, profile: profile))
    #expect(try errorCode(denied) == "ACCESS_DENIED")
    let oversized = try await endpoint.respond(
      callRequest(token: credential.token, profile: profile, name: "moolah_large")
    )
    #expect(try errorCode(oversized) == "RESULT_TOO_LARGE")
    #expect((oversized.bodyData?.count ?? 0) < 4096)
  }

  @Test
  func rechecksAfterPermissionChangesAndNeverSerializesAnUnexpectedError() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Fixture", profileIDs: [profile])
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [
        tool { _ in
          try await store.revoke(id: credential.grant.id)
          return .init(
            structuredContent: .object(["fixture": .string("private-financial-fixture")])
          )
        },
        tool(name: "moolah_error") { _ in throw SensitiveFixtureError() },
      ]
    )
    let safeFailure = try await endpoint.respond(
      callRequest(token: credential.token, profile: profile, name: "moolah_error")
    )
    #expect(try errorCode(safeFailure) == "QUERY_FAILED")
    let text = try #require(String(bytes: safeFailure.bodyData ?? Data(), encoding: .utf8))
    #expect(!text.contains("sensitive-fixture"))
    let revoked = try await endpoint.respond(callRequest(token: credential.token, profile: profile))
    #expect(revoked.statusCode == 401)
    let revokedText = try #require(String(bytes: revoked.bodyData ?? Data(), encoding: .utf8))
    #expect(!revokedText.contains("private-financial-fixture"))
  }

  @Test
  func admissionReturnsHTTPRateLimitBeforeBodyCollection() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let credential = try await store.create(label: "Fixture", profileIDs: [UUID()])
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: []
    )
    let request = try request(token: credential.token, method: "ping")
    for _ in 0..<60 { #expect(await endpoint.admission(request) == nil) }
    let denied = await endpoint.admission(request)
    #expect(denied?.statusCode == 429)
    #expect(denied?.headers["Retry-After"] == "60")
  }

  private func tool(
    name: String = "moolah_probe",
    scope: MCPReadScope = .accounts,
    handler: @escaping @Sendable (MCPToolInvocation) async throws -> CallTool.Result = { _ in
      .init()
    }
  ) -> MCPAuthorizedTool {
    MCPAuthorizedTool(
      schema: Tool(name: name, description: "Synthetic fixture", inputSchema: .object([:])),
      scope: scope,
      handler: handler
    )
  }

  private func callRequest(token: String, profile: UUID, name: String = "moolah_probe") throws
    -> HTTPRequest
  {
    try request(
      token: token,
      method: "tools/call",
      parameters: [
        "name": .string(name), "arguments": .object(["profile_id": .string(profile.uuidString)]),
      ]
    )
  }

  private func request(
    token: String? = nil,
    method: String,
    parameters: [String: Value] = [:]
  ) throws -> HTTPRequest {
    var headers = [
      "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
      "MCP-Protocol-Version": "2025-11-25",
    ]
    if let token { headers["Authorization"] = "Bearer " + token }
    let body: [String: Value] = [
      "jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method),
      "params": .object(parameters),
    ]
    return HTTPRequest(
      method: "POST",
      headers: headers,
      body: try JSONEncoder().encode(body),
      path: "/mcp"
    )
  }

  private func object(_ response: HTTPResponse) throws -> [String: Any] {
    let data = try #require(response.bodyData)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func errorCode(_ response: HTTPResponse) throws -> String {
    let result = try #require(try object(response)["result"] as? [String: Any])
    #expect(result["isError"] as? Bool == true)
    let content = try #require(result["structuredContent"] as? [String: Any])
    let error = try #require(content["error"] as? [String: Any])
    return try #require(error["code"] as? String)
  }
}

private struct SensitiveFixtureError: LocalizedError {
  var errorDescription: String? { "/sensitive-fixture/private-path" }
}

extension MCPAuthenticatedEndpointTests {
  @Test(.timeLimit(.minutes(1)))
  func cancellationRequiresAValidProtocolNotification() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Fixture", profileIDs: [profile])
    let probe = MCPActiveQueryProbe()
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [
        tool { _ in
          _ = try await probe.run()
          return .init()
        }
      ]
    )
    let pending = Task {
      try await endpoint.respond(callRequest(token: credential.token, profile: profile))
    }
    await probe.waitForStarts(1)
    let invalid = try await endpoint.respond(
      cancelNotification(token: credential.token, version: "bogus")
    )
    #expect(invalid.statusCode == 400)
    #expect(await probe.cancellations == 0)
    let accepted = try await endpoint.respond(
      cancelNotification(token: credential.token, version: "2025-11-25")
    )
    #expect(accepted.statusCode == 202)
    let cancelled = try await pending.value
    #expect(try errorCode(cancelled) == "QUERY_CANCELLED")
    #expect(await probe.cancellations == 1)
  }

  private func cancelNotification(token: String, version: String) throws -> HTTPRequest {
    let base = try request(token: token, method: "ping")
    var headers = base.headers
    headers["MCP-Protocol-Version"] = version
    let body: [String: Value] = [
      "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
      "params": .object(["requestId": .int(1)]),
    ]
    return HTTPRequest(
      method: "POST",
      headers: headers,
      body: try JSONEncoder().encode(body),
      path: "/mcp"
    )
  }
}

extension MCPAuthenticatedEndpointTests {
  @Test
  func auditRecordsOnlyClosedMetadataAndFailureSuppressesResults() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let credential = try await store.create(label: "Fixture", profileIDs: [profile])
    let events = Mutex<[MCPAuditEvent]>([])
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [
        tool { _ in .init(structuredContent: .object(["private": .string("financial payload")])) }
      ],
      audit: { event in events.withLock { $0.append(event) } }
    )
    _ = try await endpoint.respond(callRequest(token: credential.token, profile: profile))
    _ = try await endpoint.respond(
      callRequest(token: credential.token, profile: profile, name: "secret search")
    )
    let recorded = events.withLock { $0 }
    #expect(recorded.count == 2)
    #expect(recorded.first?.credentialID == credential.grant.id)
    #expect(recorded.first?.profileID == profile)
    #expect(recorded.first?.outcome == "OK")
    #expect(recorded.last?.tool == "unknown")
    #expect(recorded.last?.outcome == "ACCESS_DENIED")
    let serialized = try #require(String(bytes: JSONEncoder().encode(recorded), encoding: .utf8))
    #expect(!serialized.contains(credential.token))
    #expect(!serialized.contains("financial payload"))
    #expect(!serialized.contains("secret search"))
    let failing = try MCPAuthenticatedEndpoint(
      policy: MCPRequestPolicy(port: 49137),
      grants: store,
      tools: [
        tool { _ in .init(structuredContent: .object(["private": .string("financial payload")])) }
      ],
      audit: { _ in throw SensitiveFixtureError() }
    )
    let response = try await failing.respond(callRequest(token: credential.token, profile: profile))
    #expect(try errorCode(response) == "QUERY_FAILED")
    #expect(
      !(String(bytes: response.bodyData ?? Data(), encoding: .utf8) ?? "").contains(
        "financial payload"
      )
    )
  }
}
