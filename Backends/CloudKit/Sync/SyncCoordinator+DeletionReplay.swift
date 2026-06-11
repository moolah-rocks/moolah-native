@preconcurrency import CloudKit
import Foundation

// Start-time replay of the durable deletion journal (issue #1090, PR-B). A
// deletion recorded in `deletion_journal` (PR-A) survives engine-down timing
// and a sync-state reset; on the next engine start this re-enqueues each
// intent as a `.deleteRecord` so the deletion reliably reaches CloudKit instead
// of being lost with the in-memory pending state.
//
// This file holds the PURE record-id resolution (sentinel zone → real zone),
// which is the load-bearing, independently-testable core. The async start-time
// orchestration (iterate the profile-index DB + each live profile's DB, enqueue
// onto the engine, clear-on-confirm) lands alongside its dedicated adversary
// pass — replay is where deletions actually fire, so it is the highest-risk
// surface and is paced separately.

extension SyncCoordinator {
  /// Resolves journal entries read from ONE per-profile data DB to the
  /// `CKRecord.ID`s to re-enqueue as `.deleteRecord`. Every per-profile data
  /// entry carries the sentinel zone (`@profile-data`, Option B); the real
  /// zone (`profile-<id>`) is implicit in which DB the entry lives in, so it is
  /// supplied here as `dataZoneID` and applied to each record name.
  ///
  /// A non-sentinel entry in a per-profile DB is unexpected (the index zone
  /// lives in its own DB) and is skipped rather than replayed into the wrong
  /// zone — resolution never guesses.
  ///
  /// Pure + `nonisolated static` so the sentinel→real-zone mapping is unit
  /// tested without a live `CKSyncEngine`.
  nonisolated static func dataZoneDeletionReplayIDs(
    _ entries: [DeletionJournalRow], dataZoneID: CKRecordZone.ID
  ) -> [CKRecord.ID] {
    entries.compactMap { entry in
      guard entry.zoneName == DeletionJournal.profileDataSentinelZone else { return nil }
      return CKRecord.ID(recordName: entry.recordName, zoneID: dataZoneID)
    }
  }

  /// Resolves journal entries read from the profile-index DB to the
  /// `CKRecord.ID`s to re-enqueue. Index entries carry the real
  /// `profile-index` zone name already, so resolution is a direct map onto the
  /// supplied `indexZoneID`; a stray sentinel entry (which has no meaning in
  /// the index DB) is skipped.
  nonisolated static func indexZoneDeletionReplayIDs(
    _ entries: [DeletionJournalRow], indexZoneID: CKRecordZone.ID
  ) -> [CKRecord.ID] {
    entries.compactMap { entry in
      guard entry.zoneName == DeletionJournal.profileIndexZoneName else { return nil }
      return CKRecord.ID(recordName: entry.recordName, zoneID: indexZoneID)
    }
  }
}
