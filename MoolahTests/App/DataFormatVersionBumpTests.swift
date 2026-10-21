import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager — dataFormatVersion bump-on-write")
@MainActor
struct DataFormatVersionBumpTests {
  private func makeFixture() throws -> (SessionManager, any ProfileIndexRepository) {
    let containerManager = try ProfileContainerManager.forTesting()
    let repository = containerManager.profileIndexRepositoryForTesting
    return (
      SessionManager(
        resources: .disconnected,
        containerManager: containerManager,
        profileIndexRepository: repository),
      repository
    )
  }

  @Test("bumps dataFormatVersion to current when profile is below")
  func bumpsBelowCurrent() async throws {
    let (manager, repo) = try makeFixture()
    let id = UUID()
    let profile = Profile(
      id: id,
      label: "Test",
      dataFormatVersion: max(DataFormatVersion.current - 1, 0))
    try await repo.upsert(profile)

    _ = await manager.session(for: profile)

    let row = try await repo.profile(forID: id)
    #expect(row?.dataFormatVersion == DataFormatVersion.current)
  }

  @Test("does not bump when already at or above current")
  func doesNotBumpAtCurrent() async throws {
    let (manager, repo) = try makeFixture()
    let id = UUID()
    let profile = Profile(
      id: id,
      label: "Test",
      dataFormatVersion: DataFormatVersion.current)
    try await repo.upsert(profile)

    _ = await manager.session(for: profile)

    let row = try await repo.profile(forID: id)
    #expect(row?.dataFormatVersion == DataFormatVersion.current)
  }

  @Test("session.profile reflects the bumped value after .ready returns")
  func sessionProfileReflectsBump() async throws {
    let (manager, repo) = try makeFixture()
    let id = UUID()
    let profile = Profile(
      id: id,
      label: "Test",
      dataFormatVersion: max(DataFormatVersion.current - 1, 0))
    try await repo.upsert(profile)

    let result = await manager.session(for: profile)
    guard case .ready(let session) = result else {
      Issue.record("expected .ready")
      return
    }
    #expect(session.profile.dataFormatVersion == DataFormatVersion.current)
  }
}
