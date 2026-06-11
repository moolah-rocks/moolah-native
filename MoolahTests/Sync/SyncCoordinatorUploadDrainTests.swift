@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Engine-bound end-to-end drain test for the upload-queue wedge fix (#1087).
///
/// The wedge fix's other tests (`UploadQueueWedgeTests`) lock the *pure helpers*
/// (`classifyLookups`, `pendingChanges`) in isolation. This suite instead drives
/// the REAL send pipeline end to end — `nextRecordZoneChangeBatch` →
/// `dedupedPendingChanges` (scope + per-recordID dedup + `pendingZoneCreation`
/// deferral) → `selectBatchKind`/`filterChanges` → real `prefix(400)` →
/// `partitionBatch` → real `buildRecordsToSave` GRDB lookup → the real
/// `handleMissingRecordsToSave` `state.remove`/`state.add` — against a seeded
/// stale-save backlog. Nothing is re-implemented or stubbed: the records are
/// looked up through a real GRDB-backed handler (`ProfileContainerManager.forTesting()`),
/// and the pending queue is the ``PendingChangeStore`` seam in place of the
/// engine (`CKSyncEngine` has no constructible test instance).
///
/// Scope boundary: this proves the app's drain *pipeline logic* drains and stays
/// drained against a faithful, insertion-ordered model of `CKSyncEngine.State`.
/// It does NOT prove real `CKSyncEngine.State`'s add/remove/ordering semantics
/// (Apple-undocumented in full) — the ground truth for those is the live
/// migration, not this in-process test.
@Suite("SyncCoordinator upload-queue drain (engine-bound, #1088)")
@MainActor
struct SyncCoordinatorUploadDrainTests {

  /// A coordinator + the seeded pending saves ready to drain: `live` recordIDs
  /// have rows in GRDB (must upload), `stale` recordIDs do not (deleted locally
  /// before the batch — must convert to server deletions). 450 stale > the 400
  /// prefix window, so the drain must span multiple cycles. Stale saves sit at
  /// the head (the wedge shape that head-of-line-blocked the builder).
  private struct DrainFixture {
    let coordinator: SyncCoordinator
    let saves: [CKSyncEngine.PendingRecordZoneChange]
    let live: [CKRecord.ID]
    let stale: [CKRecord.ID]
  }

  private static func makeDrainFixture() async throws -> DrainFixture {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Drain", currencyCode: "AUD",
        financialYearStartMonth: 7))
    let database = try manager.database(for: profileId)
    let liveIds = (0..<5).map { _ in UUID() }
    try await database.write { database in
      for (index, id) in liveIds.enumerated() {
        try ProfileDataSyncHandlerTestSupport.accountRow(
          id: id, name: "Live\(index)", position: index
        ).upsert(database)
      }
    }
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    func recordID(_ id: UUID) -> CKRecord.ID {
      CKRecord.ID(recordType: AccountRow.recordType, uuid: id, zoneID: zoneID)
    }
    let live = liveIds.map(recordID)
    let stale = (0..<450).map { _ in recordID(UUID()) }
    let saves = (stale + live).map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
    return DrainFixture(coordinator: coordinator, saves: saves, live: live, stale: stale)
  }

  /// Models the engine dropping pending changes on a successful send: the built
  /// saves and the sent deletes, PLUS — per `CKSyncEngineState.h`'s "sends only
  /// the delete change" — any pending `.saveRecord` SUPERSEDED by a sent delete
  /// for the same record.
  ///
  /// Supersede belongs HERE (send-time), not in `add`: pre-#1087,
  /// `handleMissingRecordsToSave` added deletes WITHOUT removing the saves and the
  /// queue still wedged — proof a save and a delete for one id coexist in
  /// `pendingRecordZoneChanges` (the list `nextRecordZoneChangeBatch` selects
  /// from) until a send reconciles them. The drain itself never produces a
  /// coexisting pair — the fix removes the stale save before queuing its delete —
  /// so this models the documented behaviour for completeness and pins where it
  /// applies.
  private static func applySend(
    _ batch: CKSyncEngine.RecordZoneChangeBatch,
    to store: any PendingChangeStore
  ) {
    let sentDeletes = Set(batch.recordIDsToDelete)
    let supersededSaves = store.pendingRecordZoneChanges.filter { change in
      if case .saveRecord(let id) = change { return sentDeletes.contains(id) }
      return false
    }
    store.remove(
      pendingRecordZoneChanges:
        batch.recordsToSave.map { .saveRecord($0.recordID) }
        + batch.recordIDsToDelete.map { .deleteRecord($0) }
        + supersededSaves)
  }

  @Test(
    "a stale-save backlog drains across cycles: live records upload, stale convert to deletes, queue empties, no live record deleted"
  )
  func drainsStaleBacklogAcrossCycles() async throws {
    let fixture = try await Self.makeDrainFixture()
    let coordinator = fixture.coordinator
    let store = InMemoryPendingChangeStore(fixture.saves)
    let liveRecordIDs = fixture.live
    let staleRecordIDs = fixture.stale
    #expect(store.pendingRecordZoneChanges.count == staleRecordIDs.count + liveRecordIDs.count)

    var uploadedSaveIDs = Set<CKRecord.ID>()
    var serverDeletedIDs = Set<CKRecord.ID>()
    var cycles = 0
    let maxCycles = 20

    while !store.pendingRecordZoneChanges.isEmpty {
      cycles += 1
      try #require(
        cycles <= maxCycles,
        "queue did not drain within \(maxCycles) cycles — the upload wedge has regressed")

      guard let batch = coordinator.nextRecordZoneChangeBatch(scope: .all, state: store)
      else {
        // No batch to send this cycle, but the call may have converted a window
        // of stale saves into pending deletes (which re-schedules a send in
        // production). Keep draining; maxCycles guards against no progress.
        continue
      }

      for record in batch.recordsToSave { uploadedSaveIDs.insert(record.recordID) }
      for recordID in batch.recordIDsToDelete { serverDeletedIDs.insert(recordID) }

      // The engine drops the sent changes (and any superseded save) on send.
      Self.applySend(batch, to: store)
    }

    // 1. The queue fully drained — the wedge is gone (no permanent head-of-line block).
    #expect(
      store.pendingRecordZoneChanges.isEmpty,
      "queue must fully drain — \(store.pendingRecordZoneChanges.count) changes remain")

    // 2. Every live record was uploaded exactly as a save — none dropped.
    #expect(
      uploadedSaveIDs == Set(liveRecordIDs),
      "every live record must upload: missed \(Set(liveRecordIDs).subtracting(uploadedSaveIDs).count)"
    )

    // 3. Every stale save was converted into a server deletion.
    #expect(
      serverDeletedIDs == Set(staleRecordIDs),
      "every stale save must convert to a server deletion")

    // 4. #1087 safety invariant: no live record was ever queued for deletion.
    #expect(
      serverDeletedIDs.isDisjoint(with: Set(liveRecordIDs)),
      "#1087 safety violation: a live record was queued for server deletion")

    // 5. No stale record was ever uploaded as a live save.
    #expect(
      uploadedSaveIDs.isDisjoint(with: Set(staleRecordIDs)),
      "a stale record uploaded as a live save — lookup returned a row for a never-seeded UUID")
  }

  @Test(
    "fail-without-fix (RED): with the stale-save remove suppressed, the queue does NOT drain"
  )
  func wedgePersistsWhenStaleSavesAreNotRemoved() async throws {
    let fixture = try await Self.makeDrainFixture()
    let coordinator = fixture.coordinator
    // `NonRemovingPendingChangeStore.remove` is a no-op — the pre-#1087 wedge,
    // where stale saves were never dropped from the head of the queue.
    let store = NonRemovingPendingChangeStore(fixture.saves)
    let staleRecordIDs = Set(fixture.stale)

    var uploadedSaveIDs = Set<CKRecord.ID>()
    // Run several cycles. With the head never clearing, every cycle re-selects
    // the same un-buildable 400 stale saves; the live records (past the head)
    // are never reached and the queue never drains.
    for _ in 0..<8 {
      guard let batch = coordinator.nextRecordZoneChangeBatch(scope: .all, state: store)
      else { continue }
      for record in batch.recordsToSave { uploadedSaveIDs.insert(record.recordID) }
      Self.applySend(batch, to: store)
    }

    let remainingStaleSaves = store.pendingRecordZoneChanges.filter { change in
      guard case .saveRecord(let id) = change else { return false }
      return staleRecordIDs.contains(id)
    }
    // The wedge: every stale save is STILL pending — the head never advanced.
    #expect(remainingStaleSaves.count == staleRecordIDs.count)
    // And the live records, blocked behind the stale head, never uploaded.
    #expect(uploadedSaveIDs.isEmpty)
  }

  @Test(
    "send-time reconciliation: sending a delete also drops a coexisting pending save (delete wins)"
  )
  func sendDropsSaveSupersededByDelete() {
    let zoneID = CKRecordZone.ID(
      zoneName: "supersede-send-test", ownerName: CKCurrentUserDefaultName)
    let id = CKRecord.ID(recordType: AccountRow.recordType, uuid: UUID(), zoneID: zoneID)
    // A save and a delete for the same record coexist in the queue — `add` does
    // NOT supersede (the wedge proves they coexist until a send reconciles them).
    let store = InMemoryPendingChangeStore([.saveRecord(id), .deleteRecord(id)])
    #expect(store.pendingRecordZoneChanges.count == 2)

    // The engine sends only the delete (header: "sends only the delete change")
    // and, on success, drops both it and the superseded save.
    let batch = CKSyncEngine.RecordZoneChangeBatch(
      recordsToSave: [], recordIDsToDelete: [id], atomicByZone: false)
    Self.applySend(batch, to: store)

    #expect(
      store.pendingRecordZoneChanges.isEmpty,
      "the delete and the save it supersedes must both leave the queue on send")
  }
}
