import Foundation
import Testing

@testable import MoolahMCP

struct MCPCursorSignerTests {
  @Test
  func rejectsTamperingCrossGrantProfileFilterAndRestartReuse() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let profile = UUID()
    let first = try await store.create(label: "First", profileIDs: [profile])
    let second = try await store.create(label: "Second", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + first.token))
    let other = try #require(try await store.authenticate(header: "Bearer " + second.token))
    let binding = MCPCursorBinding(
      context: context,
      profileID: profile,
      tool: "accounts",
      canonicalFilters: Data()
    )
    let signer = try MCPCursorSigner()
    let continuation = MCPCursorContinuation(
      key: Data(UUID().uuidString.utf8),
      revision: "snapshot"
    )
    let cursor = try signer.encode(continuation: continuation, binding: binding)
    #expect(try signer.decode(cursor, binding: binding) == continuation)
    for invalid in [
      makeBinding(other, profile: profile),
      makeBinding(context, profile: UUID()),
      makeBinding(context, profile: profile, tool: "earmarks"),
      makeBinding(context, profile: profile, filters: Data([1])),
    ] {
      #expect(throws: MCPAccessFailure.cursorExpired) {
        try signer.decode(cursor, binding: invalid)
      }
    }
    #expect(throws: MCPAccessFailure.cursorExpired) {
      try signer.decode("A" + cursor.dropFirst(), binding: binding)
    }
    #expect(throws: MCPAccessFailure.cursorExpired) {
      try MCPCursorSigner().decode(cursor, binding: binding)
    }
    #expect(throws: MCPAccessFailure.cursorExpired) {
      try signer.decode(String(repeating: "a", count: 8193), binding: binding)
    }
  }

  @Test
  func expirationAndPermissionChangesInvalidateContinuations() async throws {
    let clock = MCPSecurityTestClock()
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets(), now: { clock.date })
    let profile = UUID()
    let credential = try await store.create(label: "Fixture", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let binding = MCPCursorBinding(
      context: context,
      profileID: profile,
      tool: "accounts",
      canonicalFilters: Data()
    )
    let signer = try MCPCursorSigner(uptime: { clock.uptime })
    let cursor = try signer.encode(
      continuation: .init(key: Data(), revision: "snapshot"),
      binding: binding
    )
    try await store.updatePermissions(
      id: credential.grant.id,
      profileIDs: [profile],
      scopes: [.accounts]
    )
    let updated = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let updatedBinding = MCPCursorBinding(
      context: updated,
      profileID: profile,
      tool: "accounts",
      canonicalFilters: Data()
    )
    #expect(throws: MCPAccessFailure.cursorExpired) {
      try signer.decode(cursor, binding: updatedBinding)
    }
    clock.advanceUptime(900)
    #expect(throws: MCPAccessFailure.cursorExpired) { try signer.decode(cursor, binding: binding) }
  }

  private func makeBinding(
    _ context: MCPAuthorizationContext,
    profile: UUID,
    tool: String = "accounts",
    filters: Data = Data()
  ) -> MCPCursorBinding {
    MCPCursorBinding(
      context: context,
      profileID: profile,
      tool: tool,
      canonicalFilters: filters
    )
  }

}

extension MCPCursorSignerTests {
  @Test
  func cursorLifetimeUsesElapsedTimeIndependentlyOfWallClockChanges() async throws {
    let clock = MCPSecurityTestClock()
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets(), now: { clock.date })
    let profile = UUID()
    let credential = try await store.create(label: "Fixture", profileIDs: [profile])
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    let binding = makeBinding(context, profile: profile)
    let signer = try MCPCursorSigner(uptime: { clock.uptime })
    let continuation = MCPCursorContinuation(key: Data(), revision: "snapshot")
    let cursor = try signer.encode(continuation: continuation, binding: binding)
    clock.advanceWall(100_000)
    #expect(try signer.decode(cursor, binding: binding) == continuation)
    clock.advanceWall(-200_000)
    #expect(try signer.decode(cursor, binding: binding) == continuation)
    clock.advanceUptime(899)
    #expect(try signer.decode(cursor, binding: binding) == continuation)
    clock.advanceUptime(1)
    #expect(throws: MCPAccessFailure.cursorExpired) { try signer.decode(cursor, binding: binding) }
  }
}
