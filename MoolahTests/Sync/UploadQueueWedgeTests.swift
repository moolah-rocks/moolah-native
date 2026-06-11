@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pure-helper tests for the upload-queue wedge fix (issue #1087):
/// `SyncCoordinator.classifyLookups` (the send-path partition: which records
/// upload, which absent records are removed + deleted, which failed lookups
/// stay pending) and `SyncCoordinator.pendingChanges(_:inZone:)` (the
/// delete-time purge of a removed profile's queued changes). Both are
/// `nonisolated static` and pure, so the behaviour is locked here in isolation —
/// the same shape as `NewMissingDeleteIDsTests`.
///
/// The end-to-end multi-cycle drain — driving the real
/// `nextRecordZoneChangeBatch` → `handleMissingRecordsToSave` pipeline (with the
/// actual `state.remove`/`state.add` calls and a GRDB-backed lookup) — lives in
/// `SyncCoordinatorUploadDrainTests`, via the `PendingChangeStore` seam that
/// stands in for `CKSyncEngine.State` (#1088).
@Suite("upload-queue wedge fix (issue #1087)")
struct UploadQueueWedgeTests {
  private static let zone = CKRecordZone.ID(
    zoneName: "profile-A", ownerName: CKCurrentUserDefaultName)

  private static func recordID(_ name: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zone)
  }

  private static func record(_ name: String) -> CKRecord {
    CKRecord(recordType: "Test", recordID: recordID(name, in: zone))
  }

  // MARK: - classifyLookups (send-path partition)

  /// The core wedge-drain + safety partition: a `.found` row uploads, an
  /// `.absent` row (query succeeded, row gone) is removed + queued for
  /// deletion, and a `.failed` lookup is left pending (neither uploaded nor
  /// deleted).
  @Test("found→upload, absent→remove+delete, failed→stay pending")
  func classifyPartitionsByOutcome() {
    let foundID = Self.recordID("found", in: Self.zone)
    let absentID = Self.recordID("absent", in: Self.zone)
    let failedID = Self.recordID("failed", in: Self.zone)
    let entries: [(recordID: CKRecord.ID, outcome: RecordLookupOutcome)] = [
      (foundID, .found(Self.record("found"))),
      (absentID, .absent),
      (failedID, .failed),
    ]

    let (toSave, absent) = SyncCoordinator.classifyLookups(entries)

    #expect(toSave.map(\.recordID) == [foundID])
    #expect(absent == [absentID])
    // The failed id appears in NEITHER bucket → it stays pending and is
    // never queued for server deletion.
    #expect(!absent.contains(failedID))
  }

  /// Safety regression-lock: when a whole recordType batch query FAILS (every
  /// id classified `.failed`), nothing is removed and nothing is queued for
  /// deletion — a transient GRDB error must never mass-delete live records
  /// server-side (the conflation bug this fix closes; issue #1087).
  @Test("a failed batch group removes and deletes nothing")
  func failedGroupRemovesNothing() {
    let entries = (0..<5).map { index in
      (recordID: Self.recordID("rec-\(index)", in: Self.zone), outcome: RecordLookupOutcome.failed)
    }

    let (toSave, absent) = SyncCoordinator.classifyLookups(entries)

    #expect(toSave.isEmpty)
    #expect(absent.isEmpty)
  }

  /// The wedge: a stale `.saveRecord` for a record that is gone locally (the
  /// query succeeds, the row is absent) is routed to the remove+delete bucket
  /// — the input `handleMissingRecordsToSave` uses to clear the head (2a).
  @Test("an absent record is routed to the remove+delete bucket (drains the wedge)")
  func absentRecordDrains() {
    let staleID = Self.recordID("stale-deleted-profile-leg", in: Self.zone)
    let (toSave, absent) = SyncCoordinator.classifyLookups([(staleID, .absent)])
    #expect(toSave.isEmpty)
    #expect(absent == [staleID])
  }

  // MARK: - pendingChanges(_:inZone:) (delete-time purge)

  @Test("delete-time purge selects only the target zone's pending changes")
  func pendingChangesFiltersByZone() {
    let zoneA = CKRecordZone.ID(zoneName: "profile-A", ownerName: CKCurrentUserDefaultName)
    let zoneB = CKRecordZone.ID(zoneName: "profile-B", ownerName: CKCurrentUserDefaultName)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .saveRecord(Self.recordID("a1", in: zoneA)),
      .deleteRecord(Self.recordID("a2", in: zoneA)),
      .saveRecord(Self.recordID("b1", in: zoneB)),
    ]

    #expect(SyncCoordinator.pendingChanges(changes, inZone: zoneA).count == 2)
    #expect(SyncCoordinator.pendingChanges(changes, inZone: zoneB).count == 1)
  }

  @Test("delete-time purge returns nothing when no change is in the zone")
  func pendingChangesEmptyWhenZoneAbsent() {
    let zoneA = CKRecordZone.ID(zoneName: "profile-A", ownerName: CKCurrentUserDefaultName)
    let zoneB = CKRecordZone.ID(zoneName: "profile-B", ownerName: CKCurrentUserDefaultName)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .saveRecord(Self.recordID("b1", in: zoneB))
    ]
    #expect(SyncCoordinator.pendingChanges(changes, inZone: zoneA).isEmpty)
  }
}
