@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// The fail-closed / stranded-peer-record recovery path and the release-timing
/// guards for bloated-state recovery (issue #1090 / #12). Shares fixtures with
/// `BloatStateRecoveryTests` via `BloatRecoveryTestSupport`.
@Suite("Bloated-state recovery — fail-closed + release timing (#1090 / #12)")
@MainActor
struct BloatRecoveryMarkerTests {
  private typealias Support = BloatRecoveryTestSupport

  // MARK: - Fail-closed on a journal-read failure during arming

  @Test("a read-failed shield suppresses ALL fetched saves (fail-closed), not just snapshot ids")
  func failClosedShieldSuppressesEverything() async throws {
    let (coordinator, _) = try Support.makeCoordinator()
    // Simulate the snapshot-build read-failure outcome directly.
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

  // MARK: - Stranded-peer-record recovery (the adversary's IMPORTANT)

  @Test(
    "a fail-closed snapshot marks recovery incomplete, which forces a fresh recovery next launch regardless of size"
  )
  func failClosedMarksAndForcesNextRecovery() async throws {
    let (coordinator, _) = try Support.makeCoordinator()
    #expect(!coordinator.recoveryIncomplete)
    #expect(!coordinator.isRecoveryForced)

    // A read-failed snapshot (the engine has advanced its token past the saves we
    // had to drop) sets the durable marker and fails closed. Set the active flag
    // directly rather than via `armRecoveryShield`, whose async snapshot task
    // would race this synchronous `applyRecoverySnapshot`.
    coordinator.isRecoveryShieldActive = true
    coordinator.applyRecoverySnapshot(resolved: [:], readFailed: true)
    #expect(coordinator.recoveryShieldSuppressAll)
    #expect(coordinator.recoveryIncomplete)
    #expect(coordinator.isRecoveryForced)

    // Next launch: the marker forces recovery even though the state is now small
    // (healthy size) and the size-ceiling is exhausted — only a fresh nil-reset
    // re-delivers the dropped peer record.
    #expect(
      SyncCoordinator.bloatGateOutcome(
        stateByteCount: 1024,
        allowRecovery: false,
        forceRecovery: coordinator.isRecoveryForced,
        threshold: Support.threshold) == .recovered)
  }

  @Test("a forced recovery does NOT count against the size-recovery ceiling")
  func forcedRecoveryDoesNotIncrementCeiling() throws {
    let (coordinator, _) = try Support.makeCoordinator()
    coordinator.applyRecoveryOutcome(.recovered, wasForced: true)
    #expect(coordinator.recoveryAttemptCount == 0)
    coordinator.applyRecoveryOutcome(.recovered, wasForced: false)
    #expect(coordinator.recoveryAttemptCount == 1)
  }

  @Test("a healthy launch re-arms the ceiling but does NOT clear the recovery-incomplete marker")
  func healthyLaunchKeepsTheIncompleteMarker() throws {
    let (coordinator, _) = try Support.makeCoordinator()
    coordinator.markRecoveryIncomplete()
    coordinator.applyRecoveryOutcome(.healthy, wasForced: false)
    #expect(coordinator.recoveryAttemptCount == 0)
    #expect(coordinator.recoveryIncomplete)  // survives — still forces next launch
  }

  @Test("a clean recovery clears the marker on settle; a suppress-all recovery leaves it set")
  func markerClearedOnCleanSettleButKeptOnSuppressAll() async throws {
    // Clean recovery → marker cleared on release.
    let clean = try await Support.makeShieldFixture()
    clean.coordinator.markRecoveryIncomplete()
    clean.coordinator.armRecoveryShield()
    _ = await clean.coordinator.activeRecoveryShield()  // let the snapshot build
    let cleanStore = InMemoryPendingChangeStore()
    await clean.coordinator.replayDeletionJournal(into: cleanStore)
    cleanStore.remove(pendingRecordZoneChanges: [.deleteRecord(clean.doomedID)])
    await clean.coordinator.clearConfirmedReplayedDeletions(against: cleanStore)
    Support.settleFetchSession(clean.coordinator)
    #expect(!clean.coordinator.isRecoveryShieldActive)
    #expect(!clean.coordinator.recoveryIncomplete)  // cleared

    // Suppress-all recovery → marker stays set so the next launch re-recovers.
    let (failed, _) = try Support.makeCoordinator()
    failed.markRecoveryIncomplete()
    failed.isRecoveryShieldActive = true
    failed.applyRecoverySnapshot(resolved: [:], readFailed: true)  // fail closed
    failed.recoveryReplayDidRun = true
    Support.settleFetchSession(failed)  // refetch settles; no deletes in flight
    #expect(!failed.isRecoveryShieldActive)  // released (nothing pending)
    #expect(failed.recoveryIncomplete)  // but the marker survives
  }

  // MARK: - Release guard is not timing-dependent (the MINOR)

  @Test("a fetch settling BEFORE replay runs does not release the shield early")
  func fetchSettlingBeforeReplayDoesNotRelease() async throws {
    let fixture = try await Support.makeShieldFixture()
    let coordinator = fixture.coordinator
    coordinator.armRecoveryShield()
    _ = await coordinator.activeRecoveryShield()  // build the snapshot

    // A fetch settles before replay has enqueued the deletions —
    // `replayedDeletionsInFlight` is still empty, but replay has NOT run, so the
    // shield must NOT release (else the in-flight refetch could resurrect).
    Support.settleFetchSession(coordinator)
    #expect(coordinator.isRecoveryShieldActive)
    #expect(await Support.suppresses(fixture.doomedID, coordinator))

    let store = InMemoryPendingChangeStore()
    await coordinator.replayDeletionJournal(into: store)
    store.remove(pendingRecordZoneChanges: [.deleteRecord(fixture.doomedID)])
    await coordinator.clearConfirmedReplayedDeletions(against: store)
    #expect(!coordinator.isRecoveryShieldActive)
  }
}
