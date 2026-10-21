import Foundation
import MoolahMCP
import Synchronization
import Testing

@testable import Moolah

@MainActor
struct MCPProfileLeaseExpiryTests {
  @Test
  func overlappingGrantsRetainOnlyProfilesWithAnUnexpiredGrant() async throws {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = MCPLeaseClock(instant)
    let profiles = [Profile(label: "Shared"), Profile(label: "Expires first")]
    let fixture = try await fixture(profiles: profiles, clock: clock)
    defer { fixture.cleanUp() }
    let controller = fixture.controller
    let store = try await MCPGrantStore.open(persistence: MCPTestSecrets(), now: { clock.now })
    let earlier = try await store.create(
      label: "Earlier",
      profileIDs: Set(profiles.map(\.id)),
      expiresAt: instant.addingTimeInterval(60)
    )
    let later = try await store.create(
      label: "Later",
      profileIDs: [profiles[0].id],
      expiresAt: instant.addingTimeInterval(120)
    )
    controller.grants = [earlier.grant, later.grant]
    controller.listenerGeneration = UUID()
    await controller.reconcileLeases()
    #expect(controller.leasedProfiles == Set(profiles.map(\.id)))
    clock.set(instant.addingTimeInterval(60))
    await controller.reconcileLeases()
    #expect(controller.leasedProfiles == [profiles[0].id])
    #expect(controller.sessions.sessions[profiles[1].id] == nil)
    clock.set(instant.addingTimeInterval(120))
    await controller.reconcileLeases()
    #expect(controller.leasedProfiles.isEmpty)
    #expect(controller.sessions.sessions.isEmpty)
    await controller.shutdown()
  }

  private struct Fixture {
    let controller: MCPServerController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    func cleanUp() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func fixture(profiles: [Profile], clock: MCPLeaseClock) async throws -> Fixture {
    let containers = try ProfileContainerManager.forTesting()
    for profile in profiles { try await containers.profileIndexRepository.upsert(profile) }
    let sessions = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: containers.profileIndexRepository
    )
    let suite = "mcp-expiry-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let preferences = MCPServerPreferences(defaults: defaults)
    preferences.isEnabled = true
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = MCPServerController(
      sessions: sessions,
      preferences: preferences,
      persistence: MCPTestSecrets(),
      history: MCPAuditHistory(url: directory.appendingPathComponent("audit.json")),
      now: { clock.now }
    )
    return Fixture(controller: controller, defaults: defaults, suite: suite, directory: directory)
  }
}

private final class MCPLeaseClock: Sendable {
  private let value: Mutex<Date>

  init(_ instant: Date) { value = Mutex(instant) }

  var now: Date { value.withLock { $0 } }

  func set(_ instant: Date) { value.withLock { $0 = instant } }
}
