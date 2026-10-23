import Foundation
import MoolahMCP
import Observation
import Synchronization
import Testing

@testable import Moolah

@MainActor
struct MCPReadSyncStateTests {
  @Test
  func progressChangesReachProfileStatusQueriesAndSettingsWithoutRefresh() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let manager = fixture.manager
    let coordinator = fixture.coordinator
    let profile = fixture.profile
    let controller = fixture.controller
    controller.readiness[profile.id] = "Ready"
    let service = MoolahReadQueryService(sessions: manager)
    let instant = Date(timeIntervalSince1970: 1_777_680_000)
    coordinator.progress.endReceiving(now: instant)
    #expect(manager.readSyncState == .upToDate)
    #expect(controller.readinessText(profileID: profile.id) == "Ready · Up to date")
    let status = try await manager.readProfileStatus(profileID: profile.id)
    #expect(status.syncState == "up_to_date")
    let accounts = try await service.accounts(
      profileID: profile.id, page: ReadPageRequest(), timeZone: .utc)
    #expect(accounts.metadata.syncState == "up_to_date")
    let range = try ReadDateRange(from: "2026-01-01", through: "2026-01-01", timeZone: .utc)
    let summary = try await service.summary(
      profileID: profile.id,
      query: ReadSummaryQuery(
        range: range, grouping: .none, includeNetWorth: false, includeParentTotals: false),
      reportingInstrument: nil)
    #expect(summary.metadata.syncState == "up_to_date")
    let capturedAccess = try await manager.readAccess(profileID: profile.id)
    let invalidated = Mutex(false)
    withObservationTracking {
      _ = controller.readinessText(profileID: profile.id)
    } onChange: {
      invalidated.withLock { $0 = true }
    }
    coordinator.progress.beginReceiving()
    #expect(invalidated.withLock { $0 })
    #expect(capturedAccess.syncState == .upToDate)
    let capturedStatus = try await manager.readProfileStatus(
      profileID: profile.id, syncState: capturedAccess.syncState)
    #expect(capturedStatus.syncState == "up_to_date")
    #expect(manager.readSyncState == .receiving)
    #expect(controller.readinessText(profileID: profile.id) == "Ready · Receiving from iCloud")
    let active = try await service.status(profileID: profile.id, timeZone: .utc)
    #expect(active.metadata.syncState == "receiving")
    #expect(active.items.first?.syncState == "receiving")
    coordinator.progress.setRetrying(true)
    #expect(manager.readSyncState == .retrying)
    #expect(controller.readinessText(profileID: profile.id) == "Ready · Retrying")
    controller.readiness[profile.id] = "Unavailable · check this profile in Moolah"
    #expect(
      controller.readinessText(profileID: profile.id)
        == "Unavailable · check this profile in Moolah")
    await controller.shutdown()
  }

  @Test
  func aSyncTransitionDuringValidationKeepsResponseStatesCoherent() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let manager = fixture.manager
    let coordinator = fixture.coordinator
    let profile = fixture.profile
    let index = fixture.index
    coordinator.progress.endReceiving(now: .distantPast)
    await index.transition(afterReads: 2) { coordinator.progress.beginReceiving() }
    let response = try await MoolahReadQueryService(sessions: manager).status(
      profileID: profile.id, timeZone: .utc)
    #expect(manager.readSyncState == .receiving)
    #expect(response.metadata.syncState == "up_to_date")
    #expect(response.items.first?.syncState == response.metadata.syncState)
    coordinator.progress.endReceiving(now: .distantPast)
    await index.transition(afterReads: 1) { coordinator.progress.beginReceiving() }
    let grants = try await MCPGrantStore.open(persistence: MCPTestSecrets())
    let credential = try await grants.create(label: "Sync fixture", profileIDs: [profile.id])
    let context = try #require(try await grants.authenticate(header: "Bearer \(credential.token)"))
    let registry = try MCPToolRegistry(
      service: MoolahReadQueryService(sessions: manager), grants: grants)
    let listed = try await registry.call(.profiles, context: context, arguments: [:])
    let encoded = try JSONEncoder().encode(listed.structuredContent)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let items = try #require(object["items"] as? [[String: Any]])
    #expect(manager.readSyncState == .receiving)
    #expect(object["sync_state"] as? String == "up_to_date")
    #expect(items.first?["sync_state"] as? String == "up_to_date")
  }

  @MainActor
  private struct Fixture {
    let manager: SessionManager
    let coordinator: SyncCoordinator
    let profile: Profile
    let index: MCPSyncTransitionIndex
    let controller: MCPServerController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    func cleanUp() {
      manager.removeSession(for: profile.id)
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func fixture() async throws -> Fixture {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Sync fixture")
    let base = containers.profileIndexRepositoryForTesting
    try await base.upsert(profile)
    let index = MCPSyncTransitionIndex(base: base)
    let suite = "mcp-sync-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let coordinator = SyncCoordinator(
      containerManager: containers, userDefaults: defaults, isCloudKitAvailable: true)
    let manager = SessionManager(
      resources: .disconnected, containerManager: containers,
      profileIndexRepository: index, syncCoordinator: coordinator)
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = MCPServerController(
      sessions: manager, preferences: MCPServerPreferences(defaults: defaults),
      persistence: MCPTestSecrets(),
      history: MCPAuditHistory(url: directory.appendingPathComponent("audit.json")))
    return Fixture(
      manager: manager, coordinator: coordinator, profile: profile, index: index,
      controller: controller, defaults: defaults, suite: suite, directory: directory)
  }

  @Test
  func allProgressPhasesHaveExplicitWireStates() throws {
    let suite = "mcp-sync-phases.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let progress = SyncProgress(userDefaults: defaults)
    #expect(ReadSyncState(progress: progress) == .connecting)
    progress.didStart(iCloudAvailable: true)
    #expect(ReadSyncState(progress: progress) == .connecting)
    progress.updatePendingUploads(1)
    progress.beginReceiving()
    #expect(ReadSyncState(progress: progress) == .syncing)
    progress.endReceiving(now: .distantPast)
    #expect(ReadSyncState(progress: progress) == .sending)
    progress.updatePendingUploads(0, now: .distantPast)
    #expect(ReadSyncState(progress: progress) == .upToDate)
    progress.setQuotaExceeded(true)
    #expect(ReadSyncState(progress: progress) == .storageFull)
    progress.setQuotaExceeded(false)
    progress.setICloudUnavailable(reason: .notSignedIn)
    #expect(ReadSyncState(progress: progress) == .unavailable)
    #expect(ReadSyncState(progress: nil) == .unknown)
  }
}

/// Changes progress during an awaited index read, without sleeps or engine/network activity.
private actor MCPSyncTransitionIndex: ProfileIndexRepository {
  let base: any ProfileIndexRepository
  private var readsUntilTransition = 0
  private var onTransition: (@MainActor @Sendable () -> Void)?

  init(base: any ProfileIndexRepository) { self.base = base }

  func transition(afterReads: Int, perform: @escaping @MainActor @Sendable () -> Void) {
    readsUntilTransition = afterReads
    onTransition = perform
  }

  func profile(forID id: UUID) async throws -> Profile? {
    if readsUntilTransition > 0 {
      readsUntilTransition -= 1
      if readsUntilTransition == 0, let onTransition {
        self.onTransition = nil
        await onTransition()
      }
    }
    return try await base.profile(forID: id)
  }

  func fetchAll() async throws -> [Profile] { try await base.fetchAll() }
  func upsert(_ profile: Profile) async throws { try await base.upsert(profile) }
}
