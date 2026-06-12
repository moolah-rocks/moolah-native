@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Safe already-bloated-state recovery (issue #1090 / #12): the byte-size gate,
/// the re-armable attempt ceiling, and the recovery-scoped tombstone shield that
/// keeps the token-less post-reset refetch from resurrecting a deleted-but-
/// un-propagated record. The marker / fail-closed / release-timing cases live in
/// `BloatRecoveryMarkerTests`.
@Suite("Bloated-state recovery (#1090 / #12)")
@MainActor
struct BloatStateRecoveryTests {
  private typealias Support = BloatRecoveryTestSupport

  // MARK: - Gate decision (pure)

  @Test(
    "size-gate: oversized + allowed → .recovered; below → .healthy; oversized + !allowed → skipped")
  func gateClassifiesBySizeAndPermission() {
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Support.threshold + 1, allowRecovery: true, forceRecovery: false,
        threshold: Support.threshold)
        == .recovered)
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Support.threshold + 1, allowRecovery: false, forceRecovery: false,
        threshold: Support.threshold)
        == .bloatedButSkipped)
    // boundary: == threshold is NOT bloated
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Support.threshold, allowRecovery: true, forceRecovery: false,
        threshold: Support.threshold) == .healthy)
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: 1024, allowRecovery: true, forceRecovery: false,
        threshold: Support.threshold) == .healthy)
    // No state file (first launch) is healthy, never recovered.
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: nil, allowRecovery: true, forceRecovery: false,
        threshold: Support.threshold) == .healthy)
  }

  // MARK: - Attempt ceiling (re-armable)

  @Test("attempt ceiling: recover increments; a healthy launch re-arms; N consecutive stop firing")
  func attemptCeilingIsReArmable() throws {
    let (coordinator, _) = try Support.makeCoordinator()
    #expect(coordinator.recoveryAttemptCount == 0)
    #expect(coordinator.isRecoveryAllowed)

    for _ in 0..<SyncCoordinator.bloatRecoveryAttemptCeiling {
      coordinator.applyRecoveryOutcome(.recovered, wasForced: false)
    }
    #expect(coordinator.recoveryAttemptCount == SyncCoordinator.bloatRecoveryAttemptCeiling)
    // Ceiling reached → no longer allowed → the gate would degrade to skipped.
    #expect(!coordinator.isRecoveryAllowed)
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: Support.threshold + 1,
        allowRecovery: coordinator.isRecoveryAllowed,
        forceRecovery: false,
        threshold: Support.threshold) == .bloatedButSkipped)

    // A healthy launch re-arms the count to 0 → recovery is possible again.
    coordinator.applyRecoveryOutcome(.healthy, wasForced: false)
    #expect(coordinator.recoveryAttemptCount == 0)
    #expect(coordinator.isRecoveryAllowed)
  }

  @Test("recovery is disallowed when iCloud is known-unavailable or entitlements are missing")
  func recoveryGatedOnAccountAndEntitlements() throws {
    let (signedOut, _) = try Support.makeCoordinator(iCloud: .unavailable(reason: .notSignedIn))
    #expect(!signedOut.isRecoveryAllowed)

    let (noEntitlement, _) = try Support.makeCoordinator(isCloudKitAvailable: false)
    #expect(!noEntitlement.isRecoveryAllowed)

    // `.unknown` (the usual state before the async account probe runs) is NOT
    // treated as known-unavailable — recovery is data-safe regardless.
    let (unknown, _) = try Support.makeCoordinator(iCloud: .unknown)
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

    let (allApply, none) = SyncCoordinator.partitionShieldedSaves([shielded, free], shield: [])
    #expect(allApply.count == 2)
    #expect(none.isEmpty)
  }

  // MARK: - Shield snapshot (e2e through real journals)

  @Test("arming the shield snapshots the journal union; the apply path awaits it race-free")
  func armingShieldSnapshotsJournalUnion() async throws {
    let fixture = try await Support.makeShieldFixture()
    let coordinator = fixture.coordinator

    coordinator.armRecoveryShield()
    #expect(coordinator.isRecoveryShieldActive)
    let shield = await coordinator.activeRecoveryShield()
    #expect(shield.contains(fixture.doomedID))

    // A re-delivered save for the deleted record is suppressed (NOT resurrected);
    // an unrelated incoming record is applied (the shield is scoped).
    let doomedRecord = CKRecord(recordType: CategoryRow.recordType, recordID: fixture.doomedID)
    let peerID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: UUID(), zoneID: fixture.doomedID.zoneID)
    let peerRecord = CKRecord(recordType: CategoryRow.recordType, recordID: peerID)
    let (toApply, suppressed) = SyncCoordinator.partitionShieldedSaves(
      [doomedRecord, peerRecord], shield: shield)
    #expect(suppressed.map(\.recordID) == [fixture.doomedID])
    #expect(toApply.map(\.recordID) == [peerID])
  }

  @Test(
    "the shield covers a just-deleted-un-propagated instrument: a re-delivered save is suppressed (#1097)"
  )
  func shieldCoversDeletedInstrument() async throws {
    let (coordinator, manager) = try Support.makeCoordinator()
    let indexZoneID = coordinator.profileIndexHandler.zoneID
    // Instruments are journaled in the profile-index DB; the recovery snapshot
    // unions the index DB's journal, so a journaled instrument deletion is
    // shielded for free.
    let registry = GRDBInstrumentRegistryRepository(database: manager.profileIndexDatabase)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    try await registry.remove(id: eth.id)

    coordinator.armRecoveryShield()
    let doomedID = CKRecord.ID(recordName: eth.id, zoneID: indexZoneID)
    let shield = await coordinator.activeRecoveryShield()
    #expect(shield.contains(doomedID))

    // The forced refetch re-delivers the deleted instrument → it must be
    // suppressed, not resurrected; an unrelated peer instrument applies.
    let doomedRecord = CKRecord(recordType: InstrumentRow.recordType, recordID: doomedID)
    let peerID = CKRecord.ID(recordName: "1:0xpeer", zoneID: indexZoneID)
    let peerRecord = CKRecord(recordType: InstrumentRow.recordType, recordID: peerID)
    let (toApply, suppressed) = await coordinator.recoveryShieldedSaves([doomedRecord, peerRecord])
    #expect(suppressed.map(\.recordID) == [doomedID])
    #expect(toApply.map(\.recordID) == [peerID])
  }

  @Test("an empty journal arms no shield (nothing to suppress)")
  func emptyJournalArmsNoShield() async throws {
    let (coordinator, manager) = try Support.makeCoordinator()
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Clean", currencyCode: "AUD"))
    _ = try manager.database(for: profileId)

    coordinator.armRecoveryShield()
    let shield = await coordinator.activeRecoveryShield()
    #expect(shield.isEmpty)
    #expect(!coordinator.isRecoveryShieldActive)  // deactivated — nothing to shield
  }

  // MARK: - Refetch-resurrection closed in BOTH orderings (pre-settle)

  @Test(
    "the deleted record is suppressed whether the refetch arrives before OR after replay (pre-settle, both orderings)"
  )
  func refetchSuppressedInEitherOrderingBeforeSettle() async throws {
    let fixture = try await Support.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()

    // ORDERING A — refetch BEFORE replay. The snapshot is built from the journal
    // at recovery start, independent of replay, so it's suppressed already.
    #expect(await Support.suppresses(fixture.doomedID, coordinator))

    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)
    #expect(
      store.pendingRecordZoneChanges.contains { change in
        if case .deleteRecord(let id) = change { return id == fixture.doomedID }
        return false
      })

    // ORDERING B — refetch AFTER replay. Still suppressed.
    #expect(await Support.suppresses(fixture.doomedID, coordinator))
  }

  // MARK: - Shield must OUTLIVE the forced refetch (the Critical regression lock)

  @Test(
    "the shield holds after delete-confirm until the post-recovery refetch settles, THEN a peer re-create applies"
  )
  func shieldOutlivesDeleteConfirmUntilRefetchSettles() async throws {
    let fixture = try await Support.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()

    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)

    // The `.deleteRecord` is confirmed sent — under the OLD (broken) rule the
    // shield would release here. But the forced full refetch may still be
    // draining, so it MUST stay armed.
    store.remove(pendingRecordZoneChanges: [.deleteRecord(fixture.doomedID)])
    await coordinator.clearConfirmedReplayedDeletions(against: store)
    #expect(coordinator.isRecoveryShieldActive)
    #expect(await Support.suppresses(fixture.doomedID, coordinator))

    // Only once a full fetch session completes does the shield release — now a
    // genuine later peer re-create of that id applies normally.
    Support.settleFetchSession(coordinator)
    #expect(!coordinator.isRecoveryShieldActive)
    #expect(!(await Support.suppresses(fixture.doomedID, coordinator)))
  }

  @Test("the shield also releases when the refetch settles before the delete is confirmed")
  func shieldReleasesWhenRefetchSettlesThenDeleteConfirms() async throws {
    let fixture = try await Support.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()

    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)

    // Refetch settles FIRST — but the deletion isn't confirmed yet, so the
    // shield must stay armed (the record is still on the server).
    Support.settleFetchSession(coordinator)
    #expect(coordinator.isRecoveryShieldActive)
    #expect(await Support.suppresses(fixture.doomedID, coordinator))

    store.remove(pendingRecordZoneChanges: [.deleteRecord(fixture.doomedID)])
    await coordinator.clearConfirmedReplayedDeletions(against: store)
    #expect(!coordinator.isRecoveryShieldActive)
    #expect(coordinator.recoveringDeletions.isEmpty)
  }
}
