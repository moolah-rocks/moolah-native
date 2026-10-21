import Darwin
import Foundation
import MoolahMCP
import Testing

@testable import Moolah

@MainActor
struct MCPServerControllerTests {
  @Test
  func freshPreferencesNeverStartAListenerOrReadCredentials() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller
    #expect(!controller.isEnabled)
    #expect(controller.port == 49137)
    controller.startIfEnabled()
    #expect(controller.commandTask == nil)
    #expect(controller.listenerTask == nil)
    #expect(controller.grantStore == nil)
    #expect(controller.leasedProfiles.isEmpty)
    await controller.shutdown()
  }

  @Test
  func configurationIsLocalAndInvalidPortsFailClosed() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller
    controller.configure(enabled: true, port: 80)
    await controller.commandTask?.value
    #expect(!controller.isEnabled)
    #expect(controller.listenerTask == nil)
    #expect(controller.errorMessage != nil)
    controller.configure(enabled: false, port: 49271)
    await controller.commandTask?.value
    #expect(controller.port == 49271)
    #expect(controller.preferences.port == 49271)
    #expect(!controller.preferences.isEnabled)
    await controller.shutdown()
  }

  @Test
  func grantCreationAndPermissionChangesNeverSelectAProfileImplicitly() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller
    controller.createIntegration(
      label: "Agent",
      profileIDs: [],
      scopes: .init([.accounts]),
      expiresAt: nil
    )
    await controller.commandTask?.value
    #expect(controller.createdCredential == nil)
    #expect(controller.grants.isEmpty)
    let profileID = UUID()
    controller.createIntegration(
      label: "Agent",
      profileIDs: [profileID],
      scopes: MCPReadScope.standard,
      expiresAt: nil
    )
    await controller.commandTask?.value
    let credential = try #require(controller.createdCredential)
    #expect(!credential.grant.scopes.contains(.transactionNotes))
    #expect(credential.grant.profileIDs == [profileID])
    #expect(controller.leasedProfiles.isEmpty)
    controller.dismissCredential()
    #expect(controller.createdCredential == nil)
    controller.revokeIntegration(credential.grant.id)
    await controller.commandTask?.value
    #expect(controller.grants.first?.revokedAt != nil)
    controller.removeRevokedIntegration(credential.grant.id)
    await controller.commandTask?.value
    #expect(controller.grants.isEmpty)
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

  private func fixture() throws -> Fixture {
    let suite = "mcp-controller-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let containers = try ProfileContainerManager.forTesting()
    let sessions = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: containers.profileIndexRepository
    )
    let controller = MCPServerController(
      sessions: sessions,
      preferences: MCPServerPreferences(defaults: defaults),
      persistence: MCPTestSecrets(),
      history: MCPAuditHistory(url: directory.appendingPathComponent("audit.json"))
    )
    return Fixture(controller: controller, defaults: defaults, suite: suite, directory: directory)
  }
}

extension MCPServerControllerTests {
  @Test
  func listenerFailureInvalidatesSuspendedLeaseAcquisition() async throws {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Isolated fixture")
    let index = MCPPauseProfileIndex(profile: profile)
    let sessions = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: index
    )
    let suite = "mcp-failure-test.\(UUID().uuidString)"
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
    let grant = try await store.create(label: "Fixture", profileIDs: [profile.id])
    controller.grants = [grant.grant]
    let generation = UUID()
    controller.listenerGeneration = generation
    let pending = Task { await controller.reconcileLeases() }
    await index.waitForRead()
    await controller.listenerFailed(generation: generation)
    await index.release()
    await pending.value
    #expect(controller.leasedProfiles.isEmpty)
    #expect(sessions.sessions.isEmpty)
    #expect(controller.readiness.isEmpty)
    #expect(controller.state == .failed)
    await controller.shutdown()
  }
}

private actor MCPPauseProfileIndex: ProfileIndexRepository {
  let profile: Profile
  private var shouldPause = true
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?

  init(profile: Profile) { self.profile = profile }

  func waitForRead() async {
    if entered { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func release() {
    gate?.resume()
    gate = nil
  }

  func profile(forID id: UUID) async throws -> Profile? {
    if shouldPause {
      shouldPause = false
      entered = true
      waiter?.resume()
      waiter = nil
      await withCheckedContinuation { gate = $0 }
    }
    return profile.id == id ? profile : nil
  }

  func upsert(_ profile: Profile) async throws {}
  func fetchAll() async throws -> [Profile] { [profile] }
}

extension MCPServerControllerTests {
  @Test(.timeLimit(.minutes(1)))
  func enabledRelaunchReusesLocalPortAndDisableReleasesListener() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller
    let port = try availablePort()
    controller.configure(enabled: true, port: port)
    await controller.commandTask?.value
    #expect(controller.state == .running)
    #expect(controller.preferences.isEnabled)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel() }
    let url = try #require(URL(string: controller.endpoint))
    let (_, response) = try await client.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
    let contender = MCPServerController(
      sessions: controller.sessions,
      preferences: controller.preferences,
      persistence: controller.persistence,
      history: controller.history
    )
    contender.startIfEnabled()
    await contender.commandTask?.value
    #expect(contender.state == .failed)
    #expect(contender.listenerTask == nil)
    #expect(controller.state == .running)
    await contender.shutdown()
    await controller.shutdown()
    #expect(controller.listenerTask == nil)
    #expect(controller.preferences.isEnabled)
    let relaunched = MCPServerController(
      sessions: controller.sessions,
      preferences: controller.preferences,
      persistence: controller.persistence,
      history: controller.history
    )
    relaunched.startIfEnabled()
    await relaunched.commandTask?.value
    #expect(relaunched.state == .running)
    #expect(relaunched.port == port)
    relaunched.configure(enabled: false, port: port)
    await relaunched.commandTask?.value
    #expect(relaunched.state == .stopped)
    #expect(relaunched.listenerTask == nil)
    #expect(relaunched.activity == nil)
    #expect(relaunched.leasedProfiles.isEmpty)
    await #expect(throws: URLError.self) { _ = try await client.data(from: url) }
    await relaunched.shutdown()
  }

  @Test
  func corruptAuditCanBeClearedBeforeStartingTheListener() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: true
    )
    try Data("invalid archive".utf8).write(
      to: fixture.directory.appendingPathComponent("audit.json")
    )
    let controller = fixture.controller
    controller.loadSettings()
    await controller.commandTask?.value
    #expect(controller.auditEntries.isEmpty)
    #expect(controller.errorMessage?.contains("Clear activity history") == true)
    controller.clearHistory()
    await controller.commandTask?.value
    #expect(controller.errorMessage == nil)
    #expect(try await controller.history.entries().isEmpty)
    controller.configure(enabled: true, port: try availablePort())
    await controller.commandTask?.value
    #expect(controller.state == .running)
    await controller.shutdown()
  }

  @Test
  func disabledLaunchPurgesExpiredHistoryWithoutCredentialsOrListener() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let old = Date(timeIntervalSince1970: 1)
    try FileManager.default.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: true
    )
    let archive = fixture.directory.appendingPathComponent("audit.json")
    let event = MCPAuditEvent(
      timestamp: old,
      credentialID: UUID(),
      tool: "unknown",
      profileID: nil,
      duration: 0,
      outcome: "OK"
    )
    try JSONEncoder().encode([event]).write(to: archive)
    let controller = fixture.controller
    controller.startIfEnabled()
    await controller.auditStartupTask?.value
    #expect(try JSONDecoder().decode([MCPAuditEvent].self, from: Data(contentsOf: archive)).isEmpty)
    #expect(controller.grantStore == nil)
    #expect(controller.listenerTask == nil)
    #expect(!controller.isEnabled)
    await controller.shutdown()
    #expect(controller.auditMaintenanceTask == nil)
  }

  @Test
  func delayedBackgroundAuditErrorCannotOverwriteSuccessfulClear() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: true
    )
    try Data("invalid archive".utf8).write(
      to: fixture.directory.appendingPathComponent("audit.json")
    )
    let controller = fixture.controller
    let gate = MCPAuditPublishGate()
    let background = Task { await controller.pruneHistory { await gate.pause() } }
    await gate.waitForPause()
    controller.clearHistory()
    await controller.commandTask?.value
    await gate.release()
    await background.value
    #expect(controller.errorMessage == nil)
    #expect(try await controller.history.entries().isEmpty)
    await controller.shutdown()
  }

  private func availablePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    #expect(result == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    #expect(named == 0)
    return Int(UInt16(bigEndian: address.sin_port))
  }
}

private actor MCPAuditPublishGate {
  private var paused = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var continuation: CheckedContinuation<Void, Never>?

  func pause() async {
    paused = true
    waiter?.resume()
    waiter = nil
    await withCheckedContinuation { continuation = $0 }
  }

  func waitForPause() async {
    if paused { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
