@preconcurrency import CloudKit
import Foundation

// Start-time reconciliation of the pending-change queue against the live
// profile set (issue #1091). `purgePendingChanges(forProfileZone:)` no-ops on a
// nil `syncEngine`, so a profile deleted before or during `init` orphans its
// queued `.saveRecord`/`.deleteRecord` in the persisted state, re-bloating it on
// every subsequent launch. This reconciliation runs once the engine is up (in
// `completeStart`'s `zoneSetupTask`) and removes pending for any profile-data
// zone whose profile is absent from the live set.

extension SyncCoordinator {
  /// Result of reading the authoritative live profile set for reconciliation.
  /// The `available` / `unavailable` split is load-bearing: `available([])`
  /// (all profiles really deleted — safe to act on) must be distinguishable
  /// from `unavailable` (the read threw — never purge), so the result is NOT a
  /// plain `Set` where "empty" would conflate the two.
  enum LiveProfileSet: Equatable {
    /// The read succeeded; these are the live profile ids (possibly empty).
    case available(Set<UUID>)
    /// The read failed — leave all pending intact and retry next launch.
    case unavailable
  }

  /// The subset of `changes` that target a `.profileData(pid)` zone whose `pid`
  /// is not in `liveIds` (a deleted profile). Profile-index and unknown zones
  /// are never purged. Pure + `nonisolated static` so the classification is
  /// unit-testable without a live `CKSyncEngine`.
  nonisolated static func pendingToPurge(
    _ changes: [CKSyncEngine.PendingRecordZoneChange], liveIds: Set<UUID>
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    changes.filter { isPendingForDeadProfile($0, liveIds: liveIds) }
  }

  /// True when `change` targets a profile-data zone whose profile is absent
  /// from the live set. `.profileIndex` (shared registry — no separate
  /// instrument zone) and `.unknown` zones return `false` (never purged).
  nonisolated private static func isPendingForDeadProfile(
    _ change: CKSyncEngine.PendingRecordZoneChange, liveIds: Set<UUID>
  ) -> Bool {
    let zoneID: CKRecordZone.ID
    switch change {
    case .saveRecord(let id): zoneID = id.zoneID
    case .deleteRecord(let id): zoneID = id.zoneID
    @unknown default: return false
    }
    switch parseZone(zoneID) {
    case .profileData(let profileId): return !liveIds.contains(profileId)
    case .profileIndex, .unknown: return false
    }
  }
}

@MainActor
extension SyncCoordinator {
  /// Purges pending changes for profile-data zones whose profile is absent from
  /// the live set. Fetches the live set via the `throws`-propagating path and
  /// skips entirely on any error — see `liveProfileIdsForReconciliation()`. The
  /// profile-index zone (shared instrument registry) and unknown zones are
  /// never touched.
  func reconcilePendingAgainstLiveProfiles() async {
    guard syncEngine != nil else { return }
    // The live set could not be positively determined (the read threw) → skip
    // and retry next launch. NEVER purge on an unknown live set, or a transient
    // read error would orphan every profile-data zone.
    guard case .available(let liveIds) = await liveProfileIdsForReconciliation()
    else { return }
    purgePendingForDeadProfiles(liveIds: liveIds)
  }

  /// The authoritative live profile id set, fetched via the `throws`-propagating
  /// `allRowIds()`, or `.unavailable` when the read fails (→ caller skips).
  ///
  /// **Load-bearing safety.** This MUST NOT use `containerManager.allProfileIds()`,
  /// which swallows GRDB errors to `[]` — keying on that would let a transient
  /// index-DB read error present as "zero live profiles", marking every
  /// profile-data zone dead and purging all profile-data pending (catastrophic
  /// loss). The throwing path distinguishes "really empty" (all profiles
  /// deleted — `available([])`) from "couldn't read" (`unavailable`). Do NOT
  /// reuse `completeStart`'s `profileIds`.
  func liveProfileIdsForReconciliation() async -> LiveProfileSet {
    do {
      return .available(Set(try await profileIndexHandler.repository.allRowIds()))
    } catch {
      // Intentional non-propagation — see the doc comment: a failed read must
      // degrade to "skip purging", never throw out of startup.
      logger.error(
        """
        Start-time reconciliation skipped — live-profile read failed: \
        \(error, privacy: .public). Leaving all pending intact; retry next launch.
        """)
      return .unavailable
    }
  }

  /// Removes the pending changes for dead-profile zones in one `state.remove`.
  ///
  /// **Atomicity.** There is NO `await` between the `pendingRecordZoneChanges`
  /// snapshot and the `remove`, so no concurrent MainActor mutation can
  /// interleave the read and the write — do not insert an `await` here.
  ///
  /// A profile created in the gap between the `liveIds` snapshot and this
  /// filter could in principle have its just-queued pending purged (it isn't in
  /// `liveIds`); that is benign. A brand-new profile's records all have
  /// `encoded_system_fields == nil`, so the `queueUnsyncedRecordsForAllProfiles`
  /// pass later in the same `zoneSetupTask` re-queues every affected row before
  /// the first send.
  private func purgePendingForDeadProfiles(liveIds: Set<UUID>) {
    guard let syncEngine else { return }
    let stale = Self.pendingToPurge(
      syncEngine.state.pendingRecordZoneChanges, liveIds: liveIds)
    guard !stale.isEmpty else { return }
    logger.warning(
      "Start-time reconciliation: purging \(stale.count, privacy: .public) orphaned pending change(s) for deleted profile(s)"
    )
    syncEngine.state.remove(pendingRecordZoneChanges: stale)
    refreshPendingUploadsMirror()
  }
}
