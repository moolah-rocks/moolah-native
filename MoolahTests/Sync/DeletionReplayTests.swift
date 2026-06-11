@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end tests for the durable deletion-journal REPLAY (issue #1090).
///
/// The write side journals every synced deletion durably (in GRDB, not the
/// CKSyncEngine state blob) inside the same write that removes the local row.
/// This is the read side: on engine start the coordinator REPLAYS each journal
/// entry as a `.deleteRecord`, so a deletion reliably reaches CloudKit even
/// after an engine-down window or a sync-state reset wiped the in-memory pending
/// queue. The replay re-issues ONLY from a positive recorded intent — never
/// inferred from a record being absent locally.
///
/// `CKSyncEngine.State` has no constructible test instance, so these drive the
/// coordinator's replay / clear seams against an in-memory ``PendingChangeStore``
/// double (the same seam the #1088 drain tests use) — a fresh empty store models
/// the post-reset pending queue. The journal itself is written through the REAL
/// GRDB repositories, so the delete→journal and recreate→clear contracts are
/// exercised end to end.
@Suite("Deletion-journal replay (#1090)")
@MainActor
struct DeletionReplayTests {

  // MARK: - Fixture

  private struct Fixture {
    let manager: ProfileContainerManager
    let coordinator: SyncCoordinator
    let profileId: UUID
    let dataZoneID: CKRecordZone.ID
    let categories: GRDBCategoryRepository
  }

  /// A coordinator over an in-memory container with one registered profile and
  /// a real GRDB category repository wired to that profile's data DB.
  private static func makeFixture() async throws -> Fixture {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(id: profileId, label: "Replay", currencyCode: "AUD"))
    let database = try manager.database(for: profileId)
    let dataZoneID = CKRecordZone.ID(
      zoneName: DeletionJournal.dataZoneName(for: profileId),
      ownerName: CKCurrentUserDefaultName)
    return Fixture(
      manager: manager,
      coordinator: coordinator,
      profileId: profileId,
      dataZoneID: dataZoneID,
      categories: GRDBCategoryRepository(database: database))
  }

  private static func deleteRecordIDs(
    _ changes: [CKSyncEngine.PendingRecordZoneChange]
  ) -> Set<CKRecord.ID> {
    Set(
      changes.compactMap { change in
        if case .deleteRecord(let id) = change { return id }
        return nil
      })
  }

  // MARK: - 1. Delete survives an engine-down / state reset → replayed

  @Test(
    "a journaled deletion survives a state reset and replays as a .deleteRecord — never inferred from absence"
  )
  func journaledDeletionSurvivesResetAndReplays() async throws {
    let fixture = try await Self.makeFixture()

    // A live category that is NEVER deleted — it must NOT be replayed (the hard
    // rule: replay only from positive journaled intent, never from absence).
    let live = try await fixture.categories.create(Moolah.Category(name: "Live"))
    // A category we delete while the engine is down — its deletion is journaled
    // durably in GRDB by the repo's in-transaction journal write.
    let doomed = try await fixture.categories.create(Moolah.Category(name: "Doomed"))
    try await fixture.categories.delete(id: doomed.id, withReplacement: nil)

    // The pending queue was wiped by the reset → start from an empty store.
    let store = InMemoryPendingChangeStore()
    await fixture.coordinator.replayDeletionJournal(into: store)

    let deletes = Self.deleteRecordIDs(store.pendingRecordZoneChanges)
    #expect(
      deletes.contains(
        CKRecord.ID(
          recordType: CategoryRow.recordType, uuid: doomed.id, zoneID: fixture.dataZoneID)))
    #expect(
      !deletes.contains(
        CKRecord.ID(
          recordType: CategoryRow.recordType, uuid: live.id, zoneID: fixture.dataZoneID)))
    // Exactly the one journaled deletion, resolved onto the real profile-<id>
    // zone (never the @profile-data sentinel).
    #expect(deletes.count == 1)
    #expect(deletes.allSatisfy { $0.zoneID == fixture.dataZoneID })
  }

  // MARK: - 2. Clear-on-recreate before replay → no spurious delete

  @Test(
    "delete-then-recreate the same id before restart leaves NO deletion to replay (the recreate cleared the journal)"
  )
  func recreateBeforeReplayClearsTheJournaledDeletion() async throws {
    let fixture = try await Self.makeFixture()

    let id = UUID()
    _ = try await fixture.categories.create(Moolah.Category(id: id, name: "First"))
    try await fixture.categories.delete(id: id, withReplacement: nil)
    // Re-create the SAME id (undo / restore / UUID reuse). The repo's create
    // clears the stale deletion intent in the same write.
    _ = try await fixture.categories.create(Moolah.Category(id: id, name: "Reborn"))

    let store = InMemoryPendingChangeStore()
    await fixture.coordinator.replayDeletionJournal(into: store)

    // No `.deleteRecord` — the live, re-created record must survive replay.
    #expect(Self.deleteRecordIDs(store.pendingRecordZoneChanges).isEmpty)
  }

  // MARK: - 3. Empty-shell resurrection closed (profile deleted while engine nil)

  @Test(
    "a profile deleted while the engine was down replays its profile-index ProfileRecord deletion (no empty-shell resurrection)"
  )
  func deletedProfileReplaysIndexRecordDeletion() async throws {
    let fixture = try await Self.makeFixture()
    let indexZoneID = fixture.coordinator.profileIndexHandler.zoneID

    // Delete the profile through the real index repository: its ProfileRecord
    // deletion is journaled in the profile-index DB (which outlives the
    // per-profile data DB teardown).
    _ = try await fixture.manager.profileIndexRepository.delete(id: fixture.profileId)

    let store = InMemoryPendingChangeStore()
    await fixture.coordinator.replayDeletionJournal(into: store)

    let expected = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: fixture.profileId, zoneID: indexZoneID)
    let deletes = Self.deleteRecordIDs(store.pendingRecordZoneChanges)
    #expect(deletes.contains(expected))
    #expect(deletes.allSatisfy { $0.zoneID == indexZoneID })
  }

  // MARK: - 4. Clear-on-confirm → no infinite re-replay across restarts

  @Test(
    "a replayed delete the engine acks is removed from the journal — it does not re-replay on the next start"
  )
  func confirmedDeletionIsClearedFromJournal() async throws {
    let fixture = try await Self.makeFixture()
    let doomed = try await fixture.categories.create(Moolah.Category(name: "Doomed"))
    try await fixture.categories.delete(id: doomed.id, withReplacement: nil)

    // Start: replay enqueues the delete.
    let store = InMemoryPendingChangeStore()
    await fixture.coordinator.replayDeletionJournal(into: store)
    let deleteID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: doomed.id, zoneID: fixture.dataZoneID)
    #expect(Self.deleteRecordIDs(store.pendingRecordZoneChanges).contains(deleteID))

    // The engine sends the delete successfully → it leaves the pending queue.
    store.remove(pendingRecordZoneChanges: [.deleteRecord(deleteID)])
    await fixture.coordinator.clearConfirmedReplayedDeletions(against: store)

    // Next start: a fresh replay finds nothing — the journal row was cleared,
    // so the delete does not re-fire forever.
    let nextStore = InMemoryPendingChangeStore()
    await fixture.coordinator.replayDeletionJournal(into: nextStore)
    #expect(Self.deleteRecordIDs(nextStore.pendingRecordZoneChanges).isEmpty)
  }

  // MARK: - 5. Coexistence with #1091 start-time reconciliation

  @Test(
    "replay and dead-profile reconciliation coexist: each acts on its own zone, no double-queue, no cross-purge"
  )
  func replayCoexistsWithReconciliation() async throws {
    let fixture = try await Self.makeFixture()

    // A LIVE profile's journaled data deletion — replay must re-issue it, and
    // reconciliation (which only purges DEAD profiles' zones) must leave it be.
    let doomed = try await fixture.categories.create(Moolah.Category(name: "Doomed"))
    try await fixture.categories.delete(id: doomed.id, withReplacement: nil)
    let liveDeleteID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: doomed.id, zoneID: fixture.dataZoneID)

    // An orphaned pending save for a DEAD profile (never registered) — exactly
    // what start-time reconciliation purges.
    let deadProfileId = UUID()
    let deadZoneID = CKRecordZone.ID(
      zoneName: "profile-\(deadProfileId.uuidString)", ownerName: CKCurrentUserDefaultName)
    let orphanSaveID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: deadZoneID)
    let orphanSave = CKSyncEngine.PendingRecordZoneChange.saveRecord(orphanSaveID)

    let store = InMemoryPendingChangeStore([orphanSave])

    // zoneSetupTask order: reconcile first, then replay. Reconcile's core is the
    // tested-pure `pendingToPurge`; the live set has only `fixture.profileId`.
    let liveIds: Set<UUID> = [fixture.profileId]
    store.remove(
      pendingRecordZoneChanges:
        SyncCoordinator.pendingToPurge(store.pendingRecordZoneChanges, liveIds: liveIds))
    await fixture.coordinator.replayDeletionJournal(into: store)

    // The dead profile's orphan save was purged; the live profile's deletion was
    // replayed exactly once; nothing for the dead profile was re-queued.
    #expect(
      !store.pendingRecordZoneChanges.contains { change in
        if case .saveRecord(let id) = change { return id == orphanSaveID }
        return false
      })
    let deletes = Self.deleteRecordIDs(store.pendingRecordZoneChanges)
    #expect(deletes == [liveDeleteID])
    #expect(!deletes.contains { $0.zoneID == deadZoneID })
  }

  // MARK: - 6. Create-hook hardening: a (re)created record drops a stale pending delete

  @Test(
    "queuing a save drops any in-flight .deleteRecord for the same id (a recreated record is never killed by a stale delete)"
  )
  func savingARecordDropsStalePendingDelete() async throws {
    let fixture = try await Self.makeFixture()
    let id = UUID()
    let recordID = CKRecord.ID(
      recordType: CategoryRow.recordType, uuid: id, zoneID: fixture.dataZoneID)

    // A replayed/in-flight delete is sitting in the queue.
    let store = InMemoryPendingChangeStore([.deleteRecord(recordID)])
    // The record is (re)created → its save must supersede the stale delete.
    fixture.coordinator.applySave(recordID, to: store)

    #expect(
      store.pendingRecordZoneChanges.contains { change in
        if case .saveRecord(let saved) = change { return saved == recordID }
        return false
      })
    #expect(
      !store.pendingRecordZoneChanges.contains { change in
        if case .deleteRecord(let deleted) = change { return deleted == recordID }
        return false
      })
  }
}
