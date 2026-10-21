import Foundation
import Testing

@testable import MoolahMCP

struct MCPGrantStoreTests {
  @Test
  func createsRandomCredentialsAndPersistsOnlyVerifiers() async throws {
    let persistence = MCPMemorySecrets()
    let store = try await MCPGrantStore.open(persistence: persistence)
    let profileID = UUID()
    let first = try await store.create(label: "Fixture", profileIDs: [profileID])
    let second = try await store.create(label: "Fixture", profileIDs: [profileID])
    #expect(first.token != second.token)
    let secret = try #require(first.token.split(separator: ".").last)
    #expect(MCPSecureBytes.decoded(String(secret))?.count == 32)
    let data = try #require(try persistence.readData())
    let persisted = try #require(String(data: data, encoding: .utf8))
    #expect(!persisted.contains(first.token))
    #expect(!persisted.contains(String(secret)))
    #expect(!first.grant.scopes.contains(.transactionNotes))
    let reopened = try await MCPGrantStore.open(persistence: persistence)
    let context = try #require(try await reopened.authenticate(header: "Bearer " + first.token))
    #expect(context.profileIDs == [profileID])
    #expect(await reopened.listGrants().count == 2)
  }

  @Test
  func missingMalformedExpiredAndRevokedCredentialsFailGenerically() async throws {
    let clock = MCPSecurityTestClock()
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets(), now: { clock.date })
    let credential = try await store.create(
      label: "Expiry",
      profileIDs: [UUID()],
      expiresAt: clock.date.addingTimeInterval(1)
    )
    for header in [
      nil, "", "Bearer missing", "Basic " + credential.token, "Bearer " + credential.token + ",x",
    ] {
      #expect(try await store.authenticate(header: header) == nil)
    }
    #expect(try await store.authenticate(header: "Bearer " + credential.token) != nil)
    clock.advanceWall(1)
    #expect(try await store.authenticate(header: "Bearer " + credential.token) == nil)
    let other = try await store.create(label: "Revoked", profileIDs: [UUID()])
    try await store.revoke(id: other.grant.id)
    #expect(try await store.authenticate(header: "Bearer " + other.token) == nil)
  }

  @Test
  func permissionsAreExplicitAndEditsInvalidateCapturedContexts() async throws {
    let store = try await MCPGrantStore.open(persistence: MCPMemorySecrets())
    let first = UUID()
    let second = UUID()
    await #expect(throws: MCPStorageFailure.invalidGrant) {
      try await store.create(label: "No profiles", profileIDs: [])
    }
    let credential = try await store.create(
      label: "Scoped",
      profileIDs: [first],
      scopes: [.accounts]
    )
    let context = try #require(try await store.authenticate(header: "Bearer " + credential.token))
    await #expect(throws: MCPAccessFailure.accessDenied) {
      try await store.execute(context: context, scope: .accounts, profileID: second) { 1 }
    }
    await #expect(throws: MCPAccessFailure.accessDenied) {
      try await store.execute(context: context, scope: .transactions, profileID: first) { 1 }
    }
    try await store.updatePermissions(
      id: credential.grant.id,
      profileIDs: [second],
      scopes: [.accounts]
    )
    await #expect(throws: MCPAccessFailure.accessDenied) { try await store.validate(context) }
  }

  @Test
  func admissionUsesABoundedMonotonicRollingMinute() async throws {
    let clock = MCPSecurityTestClock()
    let store = try await MCPGrantStore.open(
      persistence: MCPMemorySecrets(),
      now: { clock.date },
      uptime: { clock.uptime }
    )
    let credential = try await store.create(label: "Rate", profileIDs: [UUID()])
    let header = "Bearer " + credential.token
    for _ in 0..<60 { #expect(try await store.admit(header: header) != nil) }
    await #expect(throws: MCPAccessFailure.rateLimited) { try await store.admit(header: header) }
    clock.advanceWall(100_000)
    await #expect(throws: MCPAccessFailure.rateLimited) { try await store.admit(header: header) }
    clock.advanceWall(-200_000)
    await #expect(throws: MCPAccessFailure.rateLimited) { try await store.admit(header: header) }
    clock.advanceUptime(59)
    await #expect(throws: MCPAccessFailure.rateLimited) { try await store.admit(header: header) }
    clock.advanceUptime(1)
    #expect(try await store.admit(header: header) != nil)
  }

  @Test
  func persistenceFailureDoesNotPublishAPartialCredentialChange() async throws {
    let persistence = MCPMemorySecrets()
    let store = try await MCPGrantStore.open(persistence: persistence)
    let credential = try await store.create(label: "Atomic", profileIDs: [UUID()])
    _ = try await store.authenticate(header: "Bearer " + credential.token)
    persistence.state.withLock { $0.failWrites = true }
    await #expect(throws: MCPStorageFailure.unavailable) {
      try await store.revoke(id: credential.grant.id)
    }
    // The previous state is still complete. No success was reported for the failed revocation.
    #expect(try await store.authenticate(header: "Bearer " + credential.token) != nil)
    persistence.state.withLock { $0.data = Data("invalid archive".utf8) }
    await #expect(throws: MCPStorageFailure.invalidData) {
      try await MCPGrantStore.open(persistence: persistence)
    }
  }
}

extension MCPGrantStoreTests {
  @Test
  @MainActor
  func openingFromTheUIActorNeverReadsKeychainOnTheMainThread() async throws {
    _ = try await MCPGrantStore.open(persistence: RejectMainThreadSecrets())
  }

  @Test
  func revokedMetadataCanBeRemovedAtomicallyToRecoverPersistentCapacity() async throws {
    let persistence = MCPMemorySecrets()
    let store = try await MCPGrantStore.open(persistence: persistence)
    let profile = UUID()
    let active = try await store.create(label: "Active", profileIDs: [profile])
    var removable: UUID?
    for _ in 0..<99 {
      let credential = try await store.create(label: "Rotated", profileIDs: [profile])
      try await store.revoke(id: credential.grant.id)
      removable = credential.grant.id
    }
    await #expect(throws: MCPStorageFailure.grantLimit) {
      try await store.create(label: "Full", profileIDs: [profile])
    }
    await #expect(throws: MCPStorageFailure.invalidGrant) {
      try await store.removeRevoked(id: active.grant.id)
    }
    try await store.removeRevoked(id: #require(removable))
    let reopened = try await MCPGrantStore.open(persistence: persistence)
    _ = try await reopened.create(label: "Recovered", profileIDs: [profile])
    #expect(await reopened.listGrants().count == 100)
    #expect(try await reopened.authenticate(header: "Bearer " + active.token) != nil)
  }
}

private struct RejectMainThreadSecrets: MCPSecretPersisting {
  func readData() throws -> Data? {
    guard !Thread.isMainThread else { throw MCPStorageFailure.unavailable }
    return nil
  }
  func writeData(_ data: Data) throws {}
}
