import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager — compatibility gate")
@MainActor
struct SessionManagerCompatibilityTests {
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

  @Test("returns .ready when profile dataFormatVersion equals build's")
  func readyAtCurrent() async throws {
    let (manager, repo) = try makeFixture()
    let profile = Profile(label: "Test", dataFormatVersion: DataFormatVersion.current)
    try await repo.upsert(profile)

    if case .incompatible = await manager.session(for: profile) {
      Issue.record("expected .ready")
    }
  }

  @Test("returns .ready when profile dataFormatVersion is below build's")
  func readyBelowCurrent() async throws {
    let (manager, repo) = try makeFixture()
    let profile = Profile(
      label: "Test",
      dataFormatVersion: max(DataFormatVersion.current - 1, 0))
    try await repo.upsert(profile)

    if case .incompatible = await manager.session(for: profile) {
      Issue.record("expected .ready")
    }
  }

  @Test("returns .ready when profile dataFormatVersion is 0 — pre-gate baseline")
  func readyAtZero() async throws {
    let (manager, repo) = try makeFixture()
    let profile = Profile(label: "Test", dataFormatVersion: 0)
    try await repo.upsert(profile)

    if case .incompatible = await manager.session(for: profile) {
      Issue.record("expected .ready")
    }
  }

  @Test("returns .incompatible when profile dataFormatVersion exceeds build's")
  func incompatibleAboveCurrent() async throws {
    let (manager, repo) = try makeFixture()
    let profile = Profile(
      label: "Test",
      dataFormatVersion: DataFormatVersion.current + 1)
    try await repo.upsert(profile)

    let result = await manager.session(for: profile)
    guard case .incompatible(let info) = result else {
      Issue.record("expected .incompatible, got \(result)")
      return
    }
    #expect(info.profileLabel == "Test")
    #expect(info.profileVersion == DataFormatVersion.current + 1)
    #expect(info.buildVersion == DataFormatVersion.current)
  }

  @Test("does not register the per-profile zone when incompatible")
  func incompatibleDoesNotRegisterZone() async throws {
    let (manager, repo) = try makeFixture()
    let profile = Profile(
      label: "Test",
      dataFormatVersion: DataFormatVersion.current + 1)
    try await repo.upsert(profile)

    _ = await manager.session(for: profile)

    #expect(manager.sessions[profile.id] == nil)
  }

  @Test("re-reads the profile from the repository before the gate fires")
  func gateRereadsFromRepository() async throws {
    let (manager, repo) = try makeFixture()
    let id = UUID()
    let stale = Profile(id: id, label: "Stale", dataFormatVersion: 0)
    let stored = Profile(
      id: id,
      label: "Stale",
      dataFormatVersion: DataFormatVersion.current + 1)
    try await repo.upsert(stored)

    let result = await manager.session(for: stale)
    if case .ready = result {
      Issue.record("expected .incompatible — gate must re-read from repository")
    }
  }
}
