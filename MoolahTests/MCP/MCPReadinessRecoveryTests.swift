import Foundation
import MoolahMCP
import Testing

@testable import Moolah

@MainActor
struct MCPReadinessRecoveryTests {
  @Test
  func evictionDuringReadAccessDoesNotLeaveStaleLeaseBookkeeping() async throws {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Fixture")
    let index = MCPDisappearingIndex(profile: profile)
    let sessions = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: index
    )
    let suite = "mcp-recovery-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = MCPServerPreferences(defaults: defaults)
    preferences.isEnabled = true
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = MCPServerController(
      sessions: sessions,
      preferences: preferences,
      persistence: MCPTestSecrets(),
      history: MCPAuditHistory(url: directory.appendingPathComponent("audit.json"))
    )
    let store = try await MCPGrantStore.open(persistence: MCPTestSecrets())
    controller.grants = [try await store.create(label: "Fixture", profileIDs: [profile.id]).grant]
    controller.listenerGeneration = UUID()
    await controller.reconcileLeases()
    #expect(await index.reads == 2)
    #expect(controller.leasedProfiles.isEmpty)
    #expect(sessions.sessions.isEmpty)
    await index.restore()
    await controller.reconcileLeases()
    #expect(controller.leasedProfiles == [profile.id])
    #expect(sessions.sessions[profile.id] != nil)
    await controller.shutdown()
    #expect(sessions.sessions.isEmpty)
  }
}

private actor MCPDisappearingIndex: ProfileIndexRepository {
  let profile: Profile
  var reads = 0
  private var isRestored = false

  init(profile: Profile) { self.profile = profile }
  func restore() { isRestored = true }
  func profile(forID id: UUID) async throws -> Profile? {
    reads += 1
    if !isRestored, reads >= 2 { return nil }
    return profile.id == id ? profile : nil
  }
  func upsert(_ profile: Profile) async throws {}
  func fetchAll() async throws -> [Profile] { [profile] }
}
