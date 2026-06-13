@preconcurrency import CloudKit
import Foundation
import GRDB

// Start-time replay of the durable deletion journal (issue #1090). A deletion
// recorded in the `deletion_journal` table survives engine-down timing and a
// sync-state reset (it lives in GRDB, not the engine's pending state); on the
// next engine start this re-enqueues each intent as a `.deleteRecord` so the
// deletion reliably reaches CloudKit instead of being lost with the in-memory
// pending state. Resolution (sentinel zone → real zone) and the async
// orchestration (iterate the profile-index DB + each live profile's DB, enqueue
// onto the engine, clear-on-confirm) both live here.

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

// MARK: - Start-time replay orchestration

@MainActor
extension SyncCoordinator {
  /// Replays every durable deletion intent (issue #1090) onto the live engine.
  /// Called once in `completeStart`'s `zoneSetupTask`, after
  /// `reconcilePendingAgainstLiveProfiles` (issue #1091). No-op when the engine
  /// is not yet installed.
  func replayDeletionJournal() async {
    guard let syncEngine else { return }
    await replayDeletionJournal(into: syncEngine.state)
  }

  /// Reads the deletion journal from the profile-index DB and every live
  /// profile's DB, resolves each entry's real CloudKit zone (the `@profile-data`
  /// sentinel → `profile-<id>`, index entries already carry `profile-index`),
  /// and re-enqueues each as a `.deleteRecord`. Each enqueued id is tracked in
  /// `replayedDeletionsInFlight` so `clearConfirmedReplayedDeletions` can retire
  /// its journal row once the delete is acked. Keying the resolved set by
  /// `CKRecord.ID` also collapses any duplicate intent to one enqueue.
  ///
  /// `state` is a seam: production passes `syncEngine.state`; tests pass an
  /// in-memory ``PendingChangeStore`` (a fresh empty store models the
  /// post-reset pending queue, proving the deletion survived the reset).
  ///
  /// HARD RULE: every re-issued deletion comes from a positive journal row —
  /// nothing is ever inferred from a record being absent locally.
  func replayDeletionJournal(into state: any PendingChangeStore) async {
    let resolved = await resolveAllJournalDeletions().resolved
    // The coordinator may have been stopped while the journal reads were in
    // flight — don't mutate state / enqueue onto a torn-down engine.
    guard !Task.isCancelled else { return }
    if !resolved.isEmpty {
      for (id, ref) in resolved {
        replayedDeletionsInFlight[id] = ref
      }
      state.add(pendingRecordZoneChanges: resolved.keys.map { .deleteRecord($0) })
      logger.warning(
        "Deletion-journal replay: re-enqueued \(resolved.count, privacy: .public) durable deletion(s)"
      )
      refreshPendingUploadsMirror()
    }
    // Mark that replay has run this start — half of the recovery-shield release
    // condition, so a fetch settling before replay can't release it early
    // (issue #1090 / #12).
    recoveryReplayDidRun = true
  }

  /// Reads the deletion journal from the profile-index DB and every live
  /// profile's DB and resolves each row to its real CloudKit `CKRecord.ID`
  /// (sentinel `@profile-data` → `profile-<id>`; index rows already carry
  /// `profile-index`). Shared by the start-time replay and the recovery
  /// tombstone-shield snapshot (issue #1090 / #12). Keyed by `CKRecord.ID` so a
  /// duplicate intent collapses to one entry.
  ///
  /// `readFailed` is `true` when ANY journal read (or DB open) failed: the
  /// resolved set is then INCOMPLETE. The replay tolerates that (the missed rows
  /// replay next start), but the recovery shield must fail closed — see
  /// `buildRecoveryDeletionSnapshot`.
  func resolveAllJournalDeletions()
    async -> (resolved: [CKRecord.ID: ReplayedDeletionRef], readFailed: Bool)
  {
    var resolved: [CKRecord.ID: ReplayedDeletionRef] = [:]
    var readFailed = false

    do {
      let indexEntries = try await readDeletionJournal(in: containerManager.profileIndexDatabase)
      for id in Self.indexZoneDeletionReplayIDs(
        indexEntries, indexZoneID: profileIndexHandler.zoneID)
      {
        resolved[id] = ReplayedDeletionRef(
          origin: .index,
          journalZoneName: DeletionJournal.profileIndexZoneName,
          recordName: id.recordName)
      }
    } catch {
      logger.error(
        "Deletion-journal resolve: index DB read failed: \(error, privacy: .public)")
      readFailed = true
    }

    for profileId in await containerManager.allProfileIds() {
      do {
        let database = try containerManager.database(for: profileId)
        let entries = try await readDeletionJournal(in: database)
        let dataZoneID = CKRecordZone.ID(
          zoneName: DeletionJournal.dataZoneName(for: profileId),
          ownerName: CKCurrentUserDefaultName)
        for id in Self.dataZoneDeletionReplayIDs(entries, dataZoneID: dataZoneID) {
          resolved[id] = ReplayedDeletionRef(
            origin: .profileData(profileId),
            journalZoneName: DeletionJournal.profileDataSentinelZone,
            recordName: id.recordName)
        }
      } catch {
        logger.error(
          "Deletion-journal resolve: read failed for profile \(profileId, privacy: .public): \(error, privacy: .public)"
        )
        readFailed = true
      }
    }
    return (resolved, readFailed)
  }

  /// Retires journal rows for replayed deletions whose `.deleteRecord` has left
  /// the pending queue — the only signal CloudKit gives for a successful delete
  /// (`SentRecordZoneChanges` never reports `savedDeletes`). An `.unknownItem`
  /// failed-delete also leaves the queue, so this covers "server already lacks
  /// the record" too. Imperfect clearing is harmless (a redundant `.deleteRecord`
  /// next start, never data loss); the harmful re-create case is handled by the
  /// in-transaction clear that the repo's create write performs instead.
  /// Idempotent.
  func clearConfirmedReplayedDeletions() async {
    guard let syncEngine else { return }
    await clearConfirmedReplayedDeletions(against: syncEngine.state)
  }

  /// Seam-driven core of clear-on-confirm. A tracked replayed deletion whose id
  /// is no longer a pending `.deleteRecord` is treated as sent → its journal row
  /// is cleared and it is dropped from `replayedDeletionsInFlight`. Only entries
  /// the replay itself enqueued this session are considered, so an unrelated
  /// absence can never clear a row.
  func clearConfirmedReplayedDeletions(against state: any PendingChangeStore) async {
    guard !replayedDeletionsInFlight.isEmpty else { return }
    let confirmed = Self.confirmedReplayedDeletions(
      replayedDeletionsInFlight, pending: state.pendingRecordZoneChanges)
    guard !confirmed.isEmpty else { return }
    // The recovery tombstone shield snapshots the journal via an async task
    // armed at recovery start (`recoverySnapshotTask`). Clearing a journal row
    // before that read runs would let the snapshot read an already-emptied
    // journal and drop this id from the shield — so the still-draining forced
    // refetch could resurrect the just-deleted record. Await the snapshot so it
    // captures the journal BEFORE we delete from it. No-op outside a recovery
    // session (the task is nil). Issue #1090 / #12.
    await recoverySnapshotTask?.value
    // `Task.isCancelled` here is the CALLING task (e.g. `zoneSetupTask`
    // cancelled by `stop()`) while we awaited the snapshot — skip the GRDB
    // clear so we don't write through a torn-down coordinator. The snapshot
    // task's own cancellation is handled separately (`stop()` zeroes the
    // shield), so a cancelled snapshot here is harmless.
    guard !Task.isCancelled else { return }
    await clearJournalRows(for: confirmed)
    // Only retire the in-flight tracking once the journal writes have run (and
    // not after a stop cancelled them) — re-tracking on the next start is safe,
    // dropping the tracking while a row lingers is not.
    guard !Task.isCancelled else { return }
    for id in confirmed.keys {
      replayedDeletionsInFlight.removeValue(forKey: id)
    }
    // A recovery session settles once its replayed deletions are all confirmed
    // (issue #1090 / #12) — release the tombstone shield so later incoming
    // records upsert normally again.
    releaseRecoveryShieldIfSettled()
  }

  /// The subset of `inFlight` whose `.deleteRecord` is no longer in `pending` —
  /// treated as confirmed sent (CloudKit gives no positive delete ack, only the
  /// change leaving the queue). Pure + `nonisolated static` so the confirm rule
  /// is unit-testable without a live engine.
  ///
  /// "Left pending" covers one non-success case: a `zoneNotFound` /
  /// `userDeletedZone` failure removes the delete from the engine state and
  /// stashes it in `pendingZoneCreation` (not re-added to pending), so it reads
  /// as confirmed here and the journal row is cleared before any re-send. That is
  /// safe — a zone-absent error on a *delete* means the whole zone is gone
  /// server-side, so the record cannot exist and there is nothing to resurrect on
  /// a future reset. Retryable failures, by contrast, are re-added to pending by
  /// `SyncErrorRecovery.requeueFailures` (which runs inside the awaited send,
  /// before this check), so they stay tracked and are NOT cleared.
  nonisolated static func confirmedReplayedDeletions(
    _ inFlight: [CKRecord.ID: ReplayedDeletionRef],
    pending: [CKSyncEngine.PendingRecordZoneChange]
  ) -> [CKRecord.ID: ReplayedDeletionRef] {
    var stillPendingDeletes: Set<CKRecord.ID> = []
    for case .deleteRecord(let id) in pending {
      stillPendingDeletes.insert(id)
    }
    return inFlight.filter { !stillPendingDeletes.contains($0.key) }
  }

  /// Clears the journal rows for the confirmed deletions, routing each to its
  /// owning DB (the profile-index DB for index entries, each profile's data DB
  /// for data entries). Best-effort per DB — a DB that won't open leaves its
  /// rows to replay (idempotently) next start.
  private func clearJournalRows(
    for confirmed: [CKRecord.ID: ReplayedDeletionRef]
  ) async {
    var indexKeys: [(zoneName: String, recordName: String)] = []
    var dataKeysByProfile: [UUID: [(zoneName: String, recordName: String)]] = [:]
    for ref in confirmed.values {
      switch ref.origin {
      case .index:
        indexKeys.append((ref.journalZoneName, ref.recordName))
      case .profileData(let profileId):
        dataKeysByProfile[profileId, default: []].append((ref.journalZoneName, ref.recordName))
      }
    }

    if !indexKeys.isEmpty {
      await clearDeletionJournal(indexKeys, in: containerManager.profileIndexDatabase)
    }
    for (profileId, keys) in dataKeysByProfile {
      guard !Task.isCancelled else { return }
      let database: DatabaseQueue
      do {
        database = try containerManager.database(for: profileId)
      } catch {
        logger.error(
          "Clear-on-confirm: cannot open DB for profile \(profileId, privacy: .public): \(error, privacy: .public) — leaving its journal rows for the next start"
        )
        continue
      }
      await clearDeletionJournal(keys, in: database)
    }
  }

  /// Reads every deletion-journal row in `database` off the MainActor. Throws on
  /// a read error so the caller can tell "no tombstones" (`[]`) from "could not
  /// read" — the recovery shield must fail closed on the latter rather than
  /// proceed with an incomplete snapshot.
  private func readDeletionJournal(in database: DatabaseQueue) async throws -> [DeletionJournalRow]
  {
    try await database.read { try DeletionJournal.allEntries(in: $0) }
  }

  /// Clears the given journal rows in `database` off the MainActor. Best-effort:
  /// a failed clear only costs a redundant (idempotent) replay next start.
  private func clearDeletionJournal(
    _ keys: [(zoneName: String, recordName: String)], in database: DatabaseQueue
  ) async {
    do {
      try await database.write { try DeletionJournal.clear(keys, in: $0) }
    } catch {
      logger.error(
        "Clear-on-confirm journal write failed: \(error, privacy: .public) — rows will replay (idempotent) next start"
      )
    }
  }
}

/// Where a replayed deletion's journal row lives, so the clear-on-confirm sweep
/// can delete the right row once its `.deleteRecord` is acked (issue #1090).
/// `journalZoneName` is the value stored IN the row — the `@profile-data`
/// sentinel for per-profile data entries, the real `profile-index` for index
/// entries — NOT the resolved CloudKit zone.
struct ReplayedDeletionRef: Sendable, Equatable {
  let origin: ReplayedDeletionOrigin
  let journalZoneName: String
  let recordName: String
}

/// Which database a replayed deletion's journal row lives in.
enum ReplayedDeletionOrigin: Sendable, Equatable {
  case index
  case profileData(UUID)
}
