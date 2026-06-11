@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Engine-bound end-to-end drain test for the upload-queue wedge fix (#1087),
/// closing the test gap tracked as #1088.
///
/// The wedge fix's existing unit tests only exercise the *static* batch-builder
/// helpers in isolation (`newMissingDeleteIDs`, `selectBatchKind`,
/// `filterChanges`). None drive the full `nextRecordZoneChangeBatch` cycle —
/// dedup → batch-kind → `prefix(400)` window → build-or-convert-to-delete →
/// state mutation — against a seeded backlog of stale `.saveRecord`s whose rows
/// no longer exist. That whole-cycle behaviour is exactly what wedged uploads
/// before #1087, so this test drives it across multiple cycles via the
/// ``PendingChangeStore`` seam (`CKSyncEngine` itself has no constructible test
/// instance) backed by an in-memory double, with the live record lookups served
/// by a real in-memory GRDB profile.
///
/// What "simulate the engine sending a batch" means here: per Apple's
/// `CKSyncEngineState.h`, the engine "removes that change from this list" once it
/// successfully sends it. After each non-nil batch we remove its sent saves +
/// deletes from the store, exactly as the real engine would. A *nil* batch can
/// still have made progress (a cycle of all-stale saves converts them to
/// deletes via `state.remove` + `state.add`, which in production re-schedules a
/// send), so the loop continues until the queue is empty — bounded by
/// `maxCycles` so a regressed wedge (the same un-buildable 400 re-selected
/// forever) fails loudly instead of hanging.
@Suite("SyncCoordinator upload-queue drain (engine-bound, #1088)")
@MainActor
struct SyncCoordinatorUploadDrainTests {

  /// A coordinator + seeded queue ready to drain: `live` recordIDs have rows in
  /// GRDB (must upload), `stale` recordIDs do not (deleted locally before the
  /// batch — must convert to server deletions). 450 stale > the 400 prefix
  /// window, so the drain must span multiple cycles. Stale saves sit at the head
  /// (the wedge shape that head-of-line-blocked the builder).
  private struct DrainFixture {
    let coordinator: SyncCoordinator
    let store: InMemoryPendingChangeStore
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
    let store = InMemoryPendingChangeStore((stale + live).map { .saveRecord($0) })
    return DrainFixture(coordinator: coordinator, store: store, live: live, stale: stale)
  }

  @Test(
    "a stale-save backlog drains across cycles: live records upload, stale convert to deletes, queue empties, no live record deleted"
  )
  func drainsStaleBacklogAcrossCycles() async throws {
    let fixture = try await Self.makeDrainFixture()
    let coordinator = fixture.coordinator
    let store = fixture.store
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

      // The engine drops a change from pending once it sends it.
      store.remove(
        pendingRecordZoneChanges:
          batch.recordsToSave.map { .saveRecord($0.recordID) }
          + batch.recordIDsToDelete.map { .deleteRecord($0) })
    }

    // 1. The queue fully drained — the wedge is gone (no permanent head-of-line block).
    #expect(store.pendingRecordZoneChanges.isEmpty)

    // 2. Every live record was uploaded exactly as a save — none dropped.
    #expect(uploadedSaveIDs == Set(liveRecordIDs))

    // 3. Every stale save was converted into a server deletion.
    #expect(serverDeletedIDs == Set(staleRecordIDs))

    // 4. #1087 safety invariant: no live record was ever queued for deletion.
    #expect(serverDeletedIDs.isDisjoint(with: Set(liveRecordIDs)))

    // 5. No stale record was ever uploaded as a live save.
    #expect(uploadedSaveIDs.isDisjoint(with: Set(staleRecordIDs)))
  }
}
