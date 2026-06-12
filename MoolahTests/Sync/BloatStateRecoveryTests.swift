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

  // MARK: - Refetch-resurrection closed in BOTH orderings (the CRITICAL hazard)

  /// A coordinator + a profile with one locally-deleted-but-un-propagated
  /// category whose tombstone is journaled, plus the resolved `CKRecord.ID`.
  private struct ShieldFixture {
    let coordinator: SyncCoordinator
    let doomedID: CKRecord.ID
  }

  private static func makeShieldFixture() async throws -> ShieldFixture {
    let (coordinator, manager) = try makeCoordinator()
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Recover", currencyCode: "AUD"))
    let categories = GRDBCategoryRepository(database: try manager.database(for: profileId))
    let doomed = try await categories.create(Moolah.Category(name: "Doomed"))
    try await categories.delete(id: doomed.id, withReplacement: nil)
    let doomedID = CKRecord.ID(
      recordType: CategoryRow.recordType,
      uuid: doomed.id,
      zoneID: CKRecordZone.ID(
        zoneName: DeletionJournal.dataZoneName(for: profileId),
        ownerName: CKCurrentUserDefaultName))
    return ShieldFixture(coordinator: coordinator, doomedID: doomedID)
  }

  /// Drives a complete fetch session (begin → end) so the forced post-recovery
  /// refetch is considered "settled".
  private static func settleFetchSession(_ coordinator: SyncCoordinator) {
    coordinator.beginFetchingChanges()
    coordinator.endFetchingChanges()
  }

  private static func suppresses(
    _ id: CKRecord.ID, _ coordinator: SyncCoordinator
  ) async -> Bool {
    let record = CKRecord(recordType: CategoryRow.recordType, recordID: id)
    return await coordinator.recoveryShieldedSaves([record]).toApply.isEmpty
  }

  @Test(
    "the deleted record is suppressed whether the refetch arrives before OR after replay (pre-settle, both orderings)"
  )
  func refetchSuppressedInEitherOrderingBeforeSettle() async throws {
    let fixture = try await Self.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()

    // ORDERING A — refetch BEFORE replay. The shield snapshot is built from the
    // journal at recovery start, independent of replay, so the re-delivered
    // record is suppressed even though no `.deleteRecord` is enqueued yet.
    #expect(await Self.suppresses(fixture.doomedID, coordinator))

    // Replay enqueues the deletion (closes the server side).
    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)
    #expect(
      store.pendingRecordZoneChanges.contains { change in
        if case .deleteRecord(let id) = change { return id == fixture.doomedID }
        return false
      })

    // ORDERING B — refetch AFTER replay. Still suppressed.
    #expect(await Self.suppresses(fixture.doomedID, coordinator))
  }

  // MARK: - Shield must OUTLIVE the forced refetch (the Critical regression lock)

  @Test(
    "the shield holds after delete-confirm until the post-recovery refetch settles, THEN a peer re-create applies"
  )
  func shieldOutlivesDeleteConfirmUntilRefetchSettles() async throws {
    let fixture = try await Self.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()

    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)

    // The `.deleteRecord` is confirmed sent — under the OLD (broken) rule the
    // shield would release here. But the forced full refetch may still be
    // draining, so it MUST stay armed: a still-in-flight re-delivery of the same
    // id would otherwise be resurrected with no tombstone left.
    store.remove(pendingRecordZoneChanges: [.deleteRecord(fixture.doomedID)])
    await coordinator.clearConfirmedReplayedDeletions(against: store)
    #expect(coordinator.isRecoveryShieldActive)
    #expect(await Self.suppresses(fixture.doomedID, coordinator))

    // Only once a full fetch session has completed does the shield release —
    // now the server no longer holds the record, so a genuine later peer
    // re-create of that id applies normally (recovery-scoped, not a veto).
    Self.settleFetchSession(coordinator)
    #expect(!coordinator.isRecoveryShieldActive)
    #expect(!(await Self.suppresses(fixture.doomedID, coordinator)))
  }

  @Test("the shield also releases when the refetch settles before the delete is confirmed")
  func shieldReleasesWhenRefetchSettlesThenDeleteConfirms() async throws {
    let fixture = try await Self.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()

    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)

    // Refetch settles FIRST — but the deletion isn't confirmed yet, so the
    // shield must stay armed (the record is still on the server).
    Self.settleFetchSession(coordinator)
    #expect(coordinator.isRecoveryShieldActive)
    #expect(await Self.suppresses(fixture.doomedID, coordinator))

    // Now the delete confirms → both conditions met → released.
    store.remove(pendingRecordZoneChanges: [.deleteRecord(fixture.doomedID)])
    await coordinator.clearConfirmedReplayedDeletions(against: store)
    #expect(!coordinator.isRecoveryShieldActive)
    #expect(coordinator.recoveringDeletions.isEmpty)
  }

  // MARK: - Fail-closed on a journal-read failure during arming

  @Test("a read-failed shield suppresses ALL fetched saves (fail-closed), not just snapshot ids")
  func failClosedShieldSuppressesEverything() async throws {
    let (coordinator, _) = try Self.makeCoordinator()
    // Simulate the snapshot-build read-failure outcome directly (the apply path
    // can't enumerate which deletions to protect → it must drop everything).
    coordinator.isRecoveryShieldActive = true
    coordinator.recoveryShieldSuppressAll = true

    let zone = CKRecordZone.ID(zoneName: "profile-x", ownerName: CKCurrentUserDefaultName)
    let anyRecord = CKRecord(
      recordType: CategoryRow.recordType,
      recordID: CKRecord.ID(recordType: CategoryRow.recordType, uuid: UUID(), zoneID: zone))
    let (toApply, suppressed) = await coordinator.recoveryShieldedSaves([anyRecord])
    #expect(toApply.isEmpty)
    #expect(suppressed.count == 1)
  }
}
