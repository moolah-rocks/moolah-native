import Foundation
import Testing

@testable import Moolah

@MainActor
struct ReadProfileValidationTests {
  @Test
  func indexCurrencyChangesBindTheReadWithoutChangingTheVisibleSession() async throws {
    let fixture = try fixture()
    let manager = fixture.manager
    let index = fixture.index
    let profile = fixture.profile
    defer { manager.removeSession(for: profile.id) }
    let session = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let original = try await manager.readAccess(profileID: profile.id)
    var updated = profile
    updated.currencyCode = "USD"
    try await index.upsert(updated)
    let current = try await manager.readAccess(profileID: profile.id)
    #expect(current.profile.currencyCode == "USD")
    #expect(session.profile.currencyCode == "AUD")
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.validateReadAccess(original)
    }
  }

  @Test
  func indexDeletionInvalidatesAnInFlightReadAndEvictsTheSession() async throws {
    let fixture = try fixture()
    let manager = fixture.manager
    let index = fixture.index
    let profile = fixture.profile
    defer { manager.removeSession(for: profile.id) }
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let access = try await manager.readAccess(profileID: profile.id)
    await index.remove()
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await manager.validateReadAccess(access)
    }
    #expect(manager.sessions.isEmpty)
  }

  @Test
  func formatBumpsInvalidateReadsEvenBeforeTheIndexObserverRuns() async throws {
    let fixture = try fixture()
    let manager = fixture.manager
    let index = fixture.index
    let profile = fixture.profile
    defer { manager.removeSession(for: profile.id) }
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let access = try await manager.readAccess(profileID: profile.id)
    var updated = profile
    updated.dataFormatVersion = DataFormatVersion.current + 1
    try await index.upsert(updated)
    await #expect(throws: ReadQueryError.profileIncompatible) {
      try await manager.validateReadAccess(access)
    }
    #expect(manager.sessions.isEmpty)
    #expect(manager.incompatibleProfiles[profile.id] != nil)
  }

  private struct Fixture {
    let manager: SessionManager
    let index: MutableReadProfileIndex
    let profile: Profile
  }

  private func fixture() throws -> Fixture {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Fixture", currencyCode: "AUD")
    let index = MutableReadProfileIndex(profile: profile)
    let manager = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: index
    )
    return Fixture(manager: manager, index: index, profile: profile)
  }
}

private actor MutableReadProfileIndex: ProfileIndexRepository {
  var profile: Profile?

  init(profile: Profile) { self.profile = profile }
  func remove() { profile = nil }
  func profile(forID id: UUID) async throws -> Profile? { profile?.id == id ? profile : nil }
  func upsert(_ profile: Profile) async throws { self.profile = profile }
  func fetchAll() async throws -> [Profile] { profile.map { [$0] } ?? [] }
}
