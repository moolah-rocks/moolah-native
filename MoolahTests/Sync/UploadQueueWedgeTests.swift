@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pure-helper tests for the upload-queue wedge fix (issue #1087):
/// `SyncCoordinator.classifyLookups` (the send-path partition: which records
/// upload, which absent records are removed + deleted, which failed lookups
/// stay pending) and `SyncCoordinator.pendingChanges(_:inZone:)` (the
/// delete-time purge of a removed profile's queued changes). Both are
/// `nonisolated static` and pure, so the behaviour is locked without driving a
/// live `CKSyncEngine` (whose `State` cannot be fabricated in a test process)
/// — the same shape as `NewMissingDeleteIDsTests`.
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

  // MARK: - Multi-cycle drain

  /// Applies one `nextRecordZoneChangeBatch` cycle to a simulated pending
  /// queue using the SAME production helpers the real path uses — the batch
  /// `prefix`, `classifyLookups`, and `handleMissingRecordsToSave`'s
  /// remove-stale-save + `newMissingDeleteIDs` semantics — plus a model of the
  /// engine removing a successfully-uploaded save on ack. Returns the next
  /// queue state.
  ///
  /// `lookup` classifies each pending save's record id (`.found`/`.absent`);
  /// `.found` saves are "uploaded" (removed, as CKSyncEngine does on ack),
  /// `.absent` saves are removed and a server deletion is queued.
  private static func drainCycle(
    _ pending: [CKSyncEngine.PendingRecordZoneChange],
    batchLimit: Int,
    lookup: (CKRecord.ID) -> RecordLookupOutcome
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    let saveIDs: [CKRecord.ID] = pending.compactMap {
      if case .saveRecord(let id) = $0 { return id }
      return nil
    }
    let batch = Array(saveIDs.prefix(batchLimit))
    guard !batch.isEmpty else { return pending }

    let (toSave, absent) = SyncCoordinator.classifyLookups(
      batch.map { (recordID: $0, outcome: lookup($0)) })

    // `handleMissingRecordsToSave`: remove the stale saves, queue novel deletes.
    let novelDeletes = SyncCoordinator.newMissingDeleteIDs(
      among: absent, pendingChanges: pending)
    let removedSaves = Set(absent).union(toSave.map(\.recordID))  // absent + uploaded

    var next = pending.filter { change in
      if case .saveRecord(let id) = change { return !removedSaves.contains(id) }
      return true
    }
    next.append(contentsOf: novelDeletes.map { .deleteRecord($0) })
    return next
  }

  /// A queue seeded with a block of stale `.saveRecord`s for gone records plus
  /// a few live ones must EMPTY of saves across repeated cycles: stale saves
  /// are removed (so the head advances instead of re-selecting the same dead
  /// 400 forever — the wedge), live saves upload, and no live record is ever
  /// queued for server deletion.
  ///
  /// This drives the real classification + dedup helpers in a multi-cycle
  /// loop. TODO(#1088): a full engine-harness e2e that drives the literal
  /// `nextRecordZoneChangeBatchOnMain` against a live `CKSyncEngine.State`
  /// (batch selection + the actual `state.remove`/`state.add` calls) is a
  /// fast-follow — https://github.com/moolah-rocks/moolah-native/issues/1088
  @Test("a queue of stale saves drains across cycles; live records survive, none deleted")
  func multiCycleDrainEmptiesStaleSaves() {
    let zone = CKRecordZone.ID(zoneName: "profile-Z", ownerName: CKCurrentUserDefaultName)
    let staleIDs = (0..<50).map { Self.recordID("stale-\($0)", in: zone) }
    let liveIDs = (0..<5).map { Self.recordID("live-\($0)", in: zone) }
    let liveSet = Set(liveIDs)
    // Interleave: a live save after every 10 stale ones, so the live records
    // are spread through the queue rather than trivially at the tail.
    var ordered: [CKRecord.ID] = []
    var liveIterator = liveIDs.makeIterator()
    for (index, stale) in staleIDs.enumerated() {
      ordered.append(stale)
      if index % 10 == 9, let live = liveIterator.next() { ordered.append(live) }
    }
    while let live = liveIterator.next() { ordered.append(live) }
    var queue: [CKSyncEngine.PendingRecordZoneChange] = ordered.map { .saveRecord($0) }

    let lookup: (CKRecord.ID) -> RecordLookupOutcome = { id in
      liveSet.contains(id) ? .found(CKRecord(recordType: "Test", recordID: id)) : .absent
    }

    // Drain to a fixed point; cap cycles well above the ceil(55/10) needed so a
    // regression that fails to drain trips the post-loop assertion, not a hang.
    func saves(_ changes: [CKSyncEngine.PendingRecordZoneChange]) -> [CKSyncEngine
      .PendingRecordZoneChange]
    {
      changes.filter { if case .saveRecord = $0 { return true } else { return false } }
    }
    for _ in 0..<50 where !saves(queue).isEmpty {
      queue = Self.drainCycle(queue, batchLimit: 10, lookup: lookup)
    }

    let deletedIDs: [CKRecord.ID] = queue.compactMap {
      if case .deleteRecord(let id) = $0 { return id }
      return nil
    }
    // The queue drained: no `.saveRecord` remains (stale removed, live uploaded).
    #expect(saves(queue).isEmpty)
    // Every stale record was queued for server deletion exactly once.
    #expect(Set(deletedIDs) == Set(staleIDs))
    // No LIVE record was ever queued for deletion (the safety invariant).
    #expect(deletedIDs.allSatisfy { !liveSet.contains($0) })
  }
}
