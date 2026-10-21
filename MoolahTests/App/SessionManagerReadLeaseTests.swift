import Foundation
import Testing

@testable import Moolah

@MainActor
struct SessionManagerReadLeaseTests {
  @Test
  func serviceOwnersShareOneSessionAndLastReleaseCleansUp() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    let firstOwner = UUID()
    let secondOwner = UUID()
    let first = try await manager.acquireReadSession(profileID: profile.id, owner: firstOwner)
    let second = try await manager.acquireReadSession(profileID: profile.id, owner: secondOwner)
    #expect(first === second)
    manager.releaseReadSession(profileID: profile.id, owner: firstOwner)
    #expect(manager.session(forID: profile.id) === first)
    manager.releaseReadSession(profileID: profile.id, owner: secondOwner)
    #expect(manager.session(forID: profile.id) == nil)
    #expect(first.setUpTask == nil)
  }

  @Test
  func releasingServiceOwnershipPreservesAnExistingWindowSession() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    let windowOwner = UUID()
    let opened = await manager.session(for: profile, windowOwner: windowOwner)
    guard case .ready(let windowSession) = opened else {
      Issue.record("Expected the window fixture to be ready")
      return
    }
    let owner = UUID()
    let serviceSession = try await manager.acquireReadSession(profileID: profile.id, owner: owner)
    #expect(serviceSession === windowSession)
    manager.releaseReadSession(profileID: profile.id, owner: owner)
    #expect(manager.session(forID: profile.id) === windowSession)
  }

  @Test
  func openingAWindowTakesOwnershipOfAServiceCreatedSession() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    let owner = UUID()
    let serviceSession = try await manager.acquireReadSession(profileID: profile.id, owner: owner)
    let windowOwner = UUID()
    _ = await manager.session(for: profile, windowOwner: windowOwner)
    manager.releaseWindowSession(owner: windowOwner)
    #expect(manager.session(forID: profile.id) === serviceSession)
    manager.releaseReadSession(profileID: profile.id, owner: owner)
    #expect(manager.session(forID: profile.id) == nil)
  }

  @Test
  func unknownProfilesAreNeverOpenedOrSubstituted() async throws {
    let (manager, _) = try await makeManager()
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.acquireReadSession(profileID: UUID(), owner: UUID())
    }
    #expect(manager.sessions.isEmpty)
  }

  @Test
  func incompatibleProfilesFailBeforeOpeningAServiceSession() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    var incompatible = profile
    incompatible.dataFormatVersion = DataFormatVersion.current + 1
    try await manager.profileIndexRepository.upsert(incompatible)
    await #expect(throws: ReadQueryError.profileIncompatible) {
      try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    }
    #expect(manager.sessions.isEmpty)
  }

  @Test
  func setupFailureNeverBecomesAReadyReadAccess() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    let result = await manager.session(for: profile)
    guard case .ready(let session) = result else {
      Issue.record("Expected setup fixture to open")
      return
    }
    session.setUpTask = Task { throw ReadQueryError.profileUnavailable }
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    }
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.readAccess(profileID: profile.id)
    }
  }

  @Test
  func evictionInvalidatesAnAccessAlreadyHandedToAQuery() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let access = try await manager.readAccess(profileID: profile.id)
    manager.removeSession(for: profile.id)
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.validateReadAccess(access)
    }
  }

  @Test
  func replacingASessionCannotRevalidateAnOldReadAccess() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let original = try await manager.readAccess(profileID: profile.id)
    manager.removeSession(for: profile.id)
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let replacement = try await manager.readAccess(profileID: profile.id)
    #expect(original.identity != replacement.identity)
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.validateReadAccess(original)
    }
  }

  @Test
  func liveIncompatibilityOverridesARootsCachedReadyResult() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    let session = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let cached = SessionOpenResult.ready(session)
    var incompatible = profile
    incompatible.dataFormatVersion = DataFormatVersion.current + 1
    try await manager.profileIndexRepository.upsert(incompatible)
    await manager.reconcileIncompatibilityFromIndexForTesting()
    guard
      case .incompatible = manager.displayedOpenResult(
        profileID: profile.id,
        cached: cached
      )
    else {
      Issue.record("Root routing must observe mid-session eviction immediately")
      return
    }
  }

  @Test
  func signOutMakesSubsequentReadAccessUnavailable() async throws {
    let (manager, profile) = try await makeManager()
    defer { manager.removeSession(for: profile.id) }
    let session = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    await session.authStore.signOut()
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.readAccess(profileID: profile.id)
    }
  }

  private func makeManager() async throws -> (SessionManager, Profile) {
    let containers = try ProfileContainerManager.forTesting()
    let repository = containers.profileIndexRepositoryForTesting
    let profile = Profile(label: "Service fixture")
    try await repository.upsert(profile)
    return (
      SessionManager(
        resources: .disconnected,
        containerManager: containers,
        profileIndexRepository: repository
      ),
      profile
    )
  }
}
