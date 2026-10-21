import Foundation
import Testing

@testable import Moolah

@MainActor
struct ReadStatusConsistencyTests {
  @Test
  func statusRejectsAProfileRenameDuringItsRead() async throws {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Original")
    let index = ReadStatusChangingIndex(profile: profile)
    let manager = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: index
    )
    defer { manager.removeSession(for: profile.id) }
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    await index.renameAfterNextRead()
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await MoolahReadQueryService(sessions: manager).status(
        profileID: profile.id,
        timeZone: .utc
      )
    }
    let current = try await MoolahReadQueryService(sessions: manager).status(
      profileID: profile.id,
      timeZone: .utc
    )
    #expect(current.items.first?.label == "Renamed")
  }
}

private actor ReadStatusChangingIndex: ProfileIndexRepository {
  var profile: Profile
  var shouldRename = false

  init(profile: Profile) { self.profile = profile }
  func renameAfterNextRead() { shouldRename = true }
  func profile(forID id: UUID) async throws -> Profile? {
    guard id == profile.id else { return nil }
    let captured = profile
    if shouldRename {
      shouldRename = false
      profile.label = "Renamed"
    }
    return captured
  }
  func upsert(_ profile: Profile) async throws { self.profile = profile }
  func fetchAll() async throws -> [Profile] { [profile] }
}
