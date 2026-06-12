@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for safe already-bloated-state recovery (issue #1090 / #12): the
/// byte-size gate, the re-armable attempt ceiling, and the recovery-scoped
/// tombstone shield that keeps the token-less post-reset refetch from
/// resurrecting a deleted-but-un-propagated record.
@Suite("Bloated-state recovery (#1090 / #12)")
@MainActor
struct BloatStateRecoveryTests {

  private static func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "bloat-recovery-test-\(UUID().uuidString)"))
  }

  private static func makeCoordinator(
    iCloud: ICloudAvailability = .available,
    isCloudKitAvailable: Bool = true
  ) throws -> (coordinator: SyncCoordinator, manager: ProfileContainerManager) {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: try makeDefaults(),
      isCloudKitAvailable: isCloudKitAvailable)
    coordinator.iCloudAvailability = iCloud
    return (coordinator, manager)
  }

  private static let threshold = SyncCoordinator.bloatRecoveryByteThreshold

  // MARK: - Gate decision (pure)

  @Test(
    "size-gate: oversized + allowed → .recovered; below → .healthy; oversized + !allowed → skipped")
  func gateClassifiesBySizeAndPermission() {
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Self.threshold + 1, allowRecovery: true, threshold: Self.threshold)
        == .recovered)
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Self.threshold + 1, allowRecovery: false, threshold: Self.threshold)
        == .bloatedButSkipped)
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Self.threshold, allowRecovery: true, threshold: Self.threshold)
        == .healthy)  // boundary: == threshold is NOT bloated
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: 1024, allowRecovery: true, threshold: Self.threshold) == .healthy)
    // No state file (first launch) is healthy, never recovered.
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: nil, allowRecovery: true, threshold: Self.threshold) == .healthy)
  }

  // MARK: - Attempt ceiling (re-armable)

  @Test("attempt ceiling: recover increments; a healthy launch re-arms; N consecutive stop firing")
  func attemptCeilingIsReArmable() throws {
    let (coordinator, _) = try Self.makeCoordinator()
    #expect(coordinator.recoveryAttemptCount == 0)
    #expect(coordinator.isRecoveryAllowed)

    // Recover up to the ceiling.
    for _ in 0..<SyncCoordinator.bloatRecoveryAttemptCeiling {
      coordinator.applyRecoveryOutcome(.recovered)
    }
    #expect(coordinator.recoveryAttemptCount == SyncCoordinator.bloatRecoveryAttemptCeiling)
    // Ceiling reached → no longer allowed → the gate would degrade to skipped.
    #expect(!coordinator.isRecoveryAllowed)
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Self.threshold + 1,
        allowRecovery: coordinator.isRecoveryAllowed,
        threshold: Self.threshold) == .bloatedButSkipped)

    // A healthy launch re-arms the count to 0 → recovery is possible again.
    coordinator.applyRecoveryOutcome(.healthy)
    #expect(coordinator.recoveryAttemptCount == 0)
    #expect(coordinator.isRecoveryAllowed)
  }

  @Test("recovery is disallowed when iCloud is known-unavailable or entitlements are missing")
  func recoveryGatedOnAccountAndEntitlements() throws {
    let (signedOut, _) = try Self.makeCoordinator(iCloud: .unavailable(reason: .notSignedIn))
    #expect(!signedOut.isRecoveryAllowed)

    let (noEntitlement, _) = try Self.makeCoordinator(isCloudKitAvailable: false)
    #expect(!noEntitlement.isRecoveryAllowed)

    // `.unknown` (the usual state before the async account probe runs) is NOT
    // treated as known-unavailable — recovery is data-safe regardless.
    let (unknown, _) = try Self.makeCoordinator(iCloud: .unknown)
    #expect(unknown.isRecoveryAllowed)
  }

  // MARK: - Shield filter (pure)

  @Test(
    "shield partition: a shielded id is suppressed, others apply; empty shield passes all through")
  func partitionShieldedSaves() {
    let zone = CKRecordZone.ID(zoneName: "profile-x", ownerName: CKCurrentUserDefaultName)
    let shieldedID = CKRecord.ID(recordType: CategoryRow.recordType, uuid: UUID(), zoneID: zone)
    let freeID = CKRecord.ID(recordType: CategoryRow.recordType, uuid: UUID(), zoneID: zone)
    let shielded = CKRecord(recordType: CategoryRow.recordType, recordID: shieldedID)
    let free = CKRecord(recordType: CategoryRow.recordType, recordID: freeID)

    let (toApply, suppressed) = SyncCoordinator.partitionShieldedSaves(
      [shielded, free], shield: [shieldedID])
    #expect(toApply.map(\.recordID) == [freeID])
    #expect(suppressed.map(\.recordID) == [shieldedID])

    // Empty shield → everything applies (the no-recovery fast path).
    let (allApply, none) = SyncCoordinator.partitionShieldedSaves([shielded, free], shield: [])
    #expect(allApply.count == 2)
    #expect(none.isEmpty)
  }

  // MARK: - Shield snapshot (e2e through real journals)

  @Test("arming the shield snapshots the journal union; the apply path awaits it race-free")
  func armingShieldSnapshotsJournalUnion() async throws {
    let (coordinator, manager) = try Self.makeCoordinator()
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Recover", currencyCode: "AUD"))
    let database = try manager.database(for: profileId)
    let categories = GRDBCategoryRepository(database: database)

    // A locally-deleted record whose `.deleteRecord` never propagated → its
    // tombstone is journaled.
    let doomed = try await categories.create(Moolah.Category(name: "Doomed"))
    try await categories.delete(id: doomed.id, withReplacement: nil)

    coordinator.armRecoveryShield()
    #expect(coordinator.isRecoveryShieldActive)
    // `activeRecoveryShield()` awaits the snapshot build, so even a fetch racing
    // the arm sees the full set (race-free, both refetch/replay orderings).
    let shield = await coordinator.activeRecoveryShield()

    let dataZoneID = CKRecordZone.ID(
      zoneName: DeletionJournal.dataZoneName(for: profileId),
      ownerName: CKCurrentUserDefaultName)
    let doomedID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: doomed.id, zoneID: dataZoneID)
    #expect(shield.contains(doomedID))

    // A re-delivered save for the deleted record is suppressed (NOT resurrected);
    // an unrelated incoming record is applied (the shield is scoped).
    let doomedRecord = CKRecord(recordType: CategoryRow.recordType, recordID: doomedID)
    let peerID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: UUID(), zoneID: dataZoneID)
    let peerRecord = CKRecord(recordType: CategoryRow.recordType, recordID: peerID)
    let (toApply, suppressed) = SyncCoordinator.partitionShieldedSaves(
      [doomedRecord, peerRecord], shield: shield)
    #expect(suppressed.map(\.recordID) == [doomedID])
    #expect(toApply.map(\.recordID) == [peerID])
  }

  @Test("an empty journal arms no shield (nothing to suppress)")
  func emptyJournalArmsNoShield() async throws {
    let (coordinator, manager) = try Self.makeCoordinator()
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Clean", currencyCode: "AUD"))
    _ = try manager.database(for: profileId)

    coordinator.armRecoveryShield()
    let shield = await coordinator.activeRecoveryShield()
    #expect(shield.isEmpty)
    #expect(!coordinator.isRecoveryShieldActive)  // deactivated — nothing to shield
  }

  // MARK: - Shield release on settle

  @Test("the shield releases once every recovered deletion is confirmed sent")
  func shieldReleasesWhenRecoverySettles() async throws {
    let (coordinator, manager) = try Self.makeCoordinator()
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Recover", currencyCode: "AUD"))
    let database = try manager.database(for: profileId)
    let categories = GRDBCategoryRepository(database: database)
    let doomed = try await categories.create(Moolah.Category(name: "Doomed"))
    try await categories.delete(id: doomed.id, withReplacement: nil)

    coordinator.armRecoveryShield()
    _ = await coordinator.activeRecoveryShield()
    #expect(coordinator.isRecoveryShieldActive)

    // Replay enqueues the deletion; once it is confirmed sent, clear-on-confirm
    // empties `replayedDeletionsInFlight` and the shield releases.
    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)
    let dataZoneID = CKRecordZone.ID(
      zoneName: DeletionJournal.dataZoneName(for: profileId),
      ownerName: CKCurrentUserDefaultName)
    let doomedID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: doomed.id, zoneID: dataZoneID)
    store.remove(pendingRecordZoneChanges: [.deleteRecord(doomedID)])
    await coordinator.clearConfirmedReplayedDeletions(against: store)

    #expect(!coordinator.isRecoveryShieldActive)
    #expect(coordinator.recoveringDeletions.isEmpty)
    #expect(await coordinator.activeRecoveryShield().isEmpty)
  }
}
