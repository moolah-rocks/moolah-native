@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the start-time pending-change reconciliation (issue #1091): once
/// the engine is up, pending changes for a profile-data zone whose profile is
/// no longer live are purged, while the profile-index zone, unknown zones, and
/// live profiles are left intact — and the live set is fetched via the
/// THROWING path so a transient read error never purges anything.
///
/// The `state.remove` itself runs against a live `CKSyncEngine` (unfabricatable
/// in the test process), so it is covered via the pure `pendingToPurge`
/// classification plus the `liveProfileIdsForReconciliation()` throwing gate —
/// the two pieces `reconcilePendingAgainstLiveProfiles` composes.
@Suite("start-time pending reconciliation (issue #1091)")
@MainActor
struct StartupReconciliationTests {
  private static func zone(_ name: String) -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
  }

  private static func dataZone(_ profileId: UUID) -> CKRecordZone.ID {
    zone("profile-\(profileId.uuidString)")
  }

  private static func save(_ name: String, in zone: CKRecordZone.ID)
    -> CKSyncEngine.PendingRecordZoneChange
  {
    .saveRecord(CKRecord.ID(recordName: name, zoneID: zone))
  }

  private static func delete(_ name: String, in zone: CKRecordZone.ID)
    -> CKSyncEngine.PendingRecordZoneChange
  {
    .deleteRecord(CKRecord.ID(recordName: name, zoneID: zone))
  }

  // MARK: - Classification (pure)

  @Test("purges a dead profile's pending; keeps live, profile-index, and unknown zones")
  func purgesOnlyDeadProfileZones() {
    let live = UUID()
    let dead = UUID()
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      Self.save("live-save", in: Self.dataZone(live)),
      Self.save("dead-save", in: Self.dataZone(dead)),
      Self.delete("dead-delete", in: Self.dataZone(dead)),
      Self.save("index", in: Self.zone("profile-index")),
      Self.save("weird", in: Self.zone("some-other-zone")),
    ]

    let purge = SyncCoordinator.pendingToPurge(changes, liveIds: [live])

    // Exactly the two dead-profile-zone changes (save + delete).
    #expect(purge.count == 2)
    #expect(purge.contains(Self.save("dead-save", in: Self.dataZone(dead))))
    #expect(purge.contains(Self.delete("dead-delete", in: Self.dataZone(dead))))
    // Live, profile-index, and unknown zones are never purged.
    #expect(!purge.contains(Self.save("live-save", in: Self.dataZone(live))))
    #expect(!purge.contains(Self.save("index", in: Self.zone("profile-index"))))
    #expect(!purge.contains(Self.save("weird", in: Self.zone("some-other-zone"))))
  }

  @Test("an empty live set purges every profile-data zone (all profiles deleted)")
  func emptyLiveSetPurgesAllProfileData() {
    let first = UUID()
    let second = UUID()
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      Self.save("a", in: Self.dataZone(first)),
      Self.save("b", in: Self.dataZone(second)),
      Self.save("index", in: Self.zone("profile-index")),
      Self.save("weird", in: Self.zone("xyz")),
    ]

    let purge = SyncCoordinator.pendingToPurge(changes, liveIds: [])

    // Both profile-data zones purged; profile-index + unknown kept.
    #expect(purge.count == 2)
    #expect(!purge.contains(Self.save("index", in: Self.zone("profile-index"))))
    #expect(!purge.contains(Self.save("weird", in: Self.zone("xyz"))))
  }

  @Test("no dead-profile pending → removes nothing (idempotent)")
  func noDeadProfilesRemovesNothing() {
    let live = UUID()
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      Self.save("live", in: Self.dataZone(live)),
      Self.save("index", in: Self.zone("profile-index")),
    ]
    #expect(SyncCoordinator.pendingToPurge(changes, liveIds: [live]).isEmpty)
  }

  // MARK: - Live-set fetch (throwing gate)

  private func makeCoordinator() throws -> (SyncCoordinator, ProfileContainerManager) {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try #require(
      UserDefaults(suiteName: "reconcile-test-\(UUID().uuidString)"))
    let coordinator = SyncCoordinator(containerManager: manager, userDefaults: defaults)
    return (coordinator, manager)
  }

  private func seedProfile(_ manager: ProfileContainerManager, id: UUID) async throws {
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: id, label: "P", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
  }

  /// REQUIRED safety lock: the reconciliation's OWN live-set read actually
  /// throws (the profile table is dropped) → `nil`, so the caller purges
  /// nothing. Exercises the real `allRowIds()` throwing path — a stub of
  /// `allProfileIds() → []` would NOT cover this.
  @Test("a throwing live-set read yields nil (skip — never purge on an unknown live set)")
  func throwingLiveSetReadYieldsNil() async throws {
    let (coordinator, manager) = try makeCoordinator()
    // Force `allRowIds()` to throw by dropping the table it queries.
    try await manager.profileIndexRepository.database.write { database in
      try database.execute(sql: "DROP TABLE profile")
    }

    let result = await coordinator.liveProfileIdsForReconciliation()

    #expect(result == .unavailable)
  }

  /// A genuinely-empty live set (no profiles, no error) is distinguished from a
  /// failed read: it returns an empty set (non-nil), which IS safe to act on.
  @Test("a genuinely-empty live set returns an empty set, not nil")
  func genuinelyEmptyLiveSetReturnsEmpty() async throws {
    let (coordinator, _) = try makeCoordinator()
    let result = await coordinator.liveProfileIdsForReconciliation()
    #expect(result == .available(Set<UUID>()))
  }

  @Test("a populated live set returns exactly the registered profile ids")
  func populatedLiveSetReturnsIds() async throws {
    let (coordinator, manager) = try makeCoordinator()
    let first = UUID()
    let second = UUID()
    try await seedProfile(manager, id: first)
    try await seedProfile(manager, id: second)

    let result = await coordinator.liveProfileIdsForReconciliation()

    #expect(result == .available(Set([first, second])))
  }
}
