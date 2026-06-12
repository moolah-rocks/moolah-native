@preconcurrency import CloudKit
import Foundation
import GRDB
import OSLog

// Safe already-bloated-state recovery (issue #1090 / #12). A persisted
// CKSyncEngine state so large it would stall `CKSyncEngine.init` is detected by
// a byte-size gate and the engine is rebuilt with `nil` state (instant init),
// self-healing on launch with no manual `syncstate` deletion. The reset is made
// delete-safe by the #1090 journal replay PLUS a recovery-scoped tombstone
// shield (below): the token-less full refetch the reset forces re-delivers any
// record deleted-but-un-propagated, and the shield stops it being re-inserted /
// its tombstone cleared, so the replayed `.deleteRecord` wins. Save-completeness
// comes from `isFirstLaunch = true` → `queueAllExistingRecordsForAllZones`.

extension SyncCoordinator {
  /// State-file byte size above which the persisted state is treated as
  /// pathological and recovered. A healthy state is KB–low-MB; the wedge that
  /// motivated this was 42.5 MB. 24 MB cleanly separates the two, and a
  /// false-positive recovery is data-safe (it costs only a one-time refetch).
  static let bloatRecoveryByteThreshold = 24 * 1024 * 1024

  /// Maximum consecutive recoveries before degrading to warning-only. A state
  /// that re-bloats on every launch (real data exceeds the gate, or a deeper
  /// bug) must not loop forever losing tokens; any healthy launch re-arms the
  /// count (see `resetRecoveryAttemptCount`).
  static let bloatRecoveryAttemptCeiling = 3

  /// UserDefaults key for the consecutive-recovery counter.
  static let bloatRecoveryAttemptCountKey = "com.moolah.sync.bloatRecoveryAttemptCount"

  // MARK: - Off-actor engine construction + gate

  /// Off-actor: reads the persisted sync state, applies the byte-size gate, and
  /// constructs the `CKSyncEngine`. The body's heavy synchronous work
  /// (`NSKeyedUnarchiver` inside `CKSyncEngine.init`) must not run on the main
  /// thread — the `nonisolated async` hop from the `@MainActor`-originating
  /// `Task {}` in `start()` is sufficient on the current toolchain (verified
  /// empirically, issue #565: `Thread.isMainThread == false` at entry, a
  /// different OS TID from the surrounding `@MainActor` `completeStart`).
  /// `Task.detached` is not required.
  ///
  /// `allowRecovery` (entitlements / account / attempt ceiling) is computed on
  /// the MainActor by `start()` and passed in; this method owns only the byte
  /// measurement and the `nil`-state rebuild on `.recovered`.
  nonisolated static func prepareEngine(
    stateFileURL: URL,
    delegate: any CKSyncEngineDelegate & Sendable,
    allowRecovery: Bool,
    bloatThreshold: Int
  ) async -> PreparedEngine {
    // A missing file is the normal first launch; a genuine read error is logged
    // (it degrades to an empty-state / full-refetch start, the safe fallback).
    let data: Data?
    do {
      data = try Data(contentsOf: stateFileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      data = nil
    } catch {
      offActorLogger.error(
        "Failed to read persisted sync-state file: \(error, privacy: .public) — starting from empty state"
      )
      data = nil
    }
    // Observe-only size logging on every launch (issue #1090 / #12) — feeds
    // threshold calibration even when the gate never fires.
    offActorLogger.info(
      "Persisted sync-state size: \(data?.count ?? 0, privacy: .public) bytes (threshold \(bloatThreshold, privacy: .public))"
    )

    let outcome = bloatGateOutcome(
      stateByteCount: data?.count, allowRecovery: allowRecovery, threshold: bloatThreshold)
    // `.recovered` drops the bloated blob → `nil` state → instant init,
    // `isFirstLaunch = true`. `.healthy` / `.bloatedButSkipped` decode and pass
    // the existing state through (off-main init absorbs any stall).
    let savedState: CKSyncEngine.State.Serialization? =
      outcome == .recovered ? nil : Self.decodeState(data)
    let configuration = CKSyncEngine.Configuration(
      database: CloudKitContainer.app.privateCloudDatabase,
      stateSerialization: savedState,
      delegate: delegate
    )
    return PreparedEngine(
      engine: CKSyncEngine(configuration),
      isFirstLaunch: savedState == nil,
      recoveryOutcome: outcome)
  }

  /// Decodes the persisted state, logging (not swallowing) a corrupt /
  /// schema-incompatible blob. A decode failure degrades to `nil` → an
  /// empty-state, full-refetch start (safe), but the operator gets a signal.
  nonisolated private static func decodeState(_ data: Data?) -> CKSyncEngine.State.Serialization? {
    guard let data else { return nil }
    do {
      return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    } catch {
      offActorLogger.error(
        "Persisted sync state failed to decode: \(error, privacy: .public) — starting from empty state"
      )
      return nil
    }
  }

  // MARK: - Gate decision (pure)

  /// Classifies the persisted state from its byte size + whether recovery is
  /// currently allowed. `nil` byteCount (no state file) is `.healthy`. Pure +
  /// `nonisolated static` so the gate is unit-tested without touching disk or a
  /// live engine.
  nonisolated static func bloatGateOutcome(
    stateByteCount: Int?, allowRecovery: Bool, threshold: Int
  ) -> BloatGateOutcome {
    guard let byteCount = stateByteCount, byteCount > threshold else { return .healthy }
    return allowRecovery ? .recovered : .bloatedButSkipped
  }

  // MARK: - Attempt counter (re-armable ceiling)

  /// Consecutive recoveries recorded so far (0 when none / re-armed).
  var recoveryAttemptCount: Int {
    userDefaults.integer(forKey: Self.bloatRecoveryAttemptCountKey)
  }

  /// Records one more consecutive recovery.
  func incrementRecoveryAttemptCount() {
    userDefaults.set(recoveryAttemptCount + 1, forKey: Self.bloatRecoveryAttemptCountKey)
  }

  /// Re-arms the ceiling — called on any launch that observes a healthy state,
  /// so a legitimately-re-bloated install months later can self-heal again.
  func resetRecoveryAttemptCount() {
    userDefaults.removeObject(forKey: Self.bloatRecoveryAttemptCountKey)
  }

  /// Whether a bloated state may be recovered right now: entitlements present,
  /// iCloud not *known* unavailable, and the consecutive-recovery ceiling not
  /// yet reached. The async account-status probe has not run at
  /// `prepareEngine` time, so `.unknown` counts as "not known-unavailable"
  /// (recovery is data-safe regardless of account state; this only avoids
  /// churning a refetch during a *known* sign-out / restricted account).
  var isRecoveryAllowed: Bool {
    guard isCloudKitAvailable else { return false }
    if case .unavailable = iCloudAvailability { return false }
    return recoveryAttemptCount < Self.bloatRecoveryAttemptCeiling
  }

  // MARK: - Outcome handling (called from completeStart)

  /// Applies the byte-size gate outcome at start: a recovery bumps the attempt
  /// count and arms the tombstone shield; a healthy launch re-arms the ceiling;
  /// a skipped-but-bloated launch warns (the existing state is running as-is).
  func applyRecoveryOutcome(_ outcome: BloatGateOutcome) {
    switch outcome {
    case .recovered:
      incrementRecoveryAttemptCount()
      logger.warning(
        "Bloated sync state recovered: rebuilt the engine with empty state (consecutive recovery #\(self.recoveryAttemptCount, privacy: .public) of \(Self.bloatRecoveryAttemptCeiling, privacy: .public))"
      )
      armRecoveryShield()
    case .healthy:
      resetRecoveryAttemptCount()
    case .bloatedButSkipped:
      logger.warning(
        "Sync state exceeds the bloat threshold but recovery was skipped (attempt ceiling reached or iCloud unavailable) — running with the existing state"
      )
    }
  }

  // MARK: - Recovery-scoped tombstone shield

  /// Arms the shield for a recovery session: spawns the snapshot build BEFORE
  /// the engine is installed, so the apply path always observes an in-flight (or
  /// finished) `recoverySnapshotTask` and never races the engine's automatic
  /// post-init fetch. Idempotent within a start.
  func armRecoveryShield() {
    isRecoveryShieldActive = true
    // Cancel any in-flight snapshot from a prior arm before replacing it, so an
    // abandoned build can't resume and overwrite the new snapshot.
    recoverySnapshotTask?.cancel()
    recoverySnapshotTask = Task { [weak self] in
      await self?.buildRecoveryDeletionSnapshot()
    }
  }

  /// Builds `recoveringDeletions` = the union of every journal deletion id
  /// (index DB + each live profile DB), resolved to its real CloudKit zone. If
  /// the journals are empty there is nothing to shield, so the shield
  /// deactivates immediately.
  private func buildRecoveryDeletionSnapshot() async {
    let resolved = await resolveAllJournalDeletions()
    // `stop()` (or a re-arm) may have cancelled us during the journal reads and
    // already cleared the shield state — don't resurrect it with a stale set.
    guard !Task.isCancelled else { return }
    recoveringDeletions = Set(resolved.keys)
    if recoveringDeletions.isEmpty {
      isRecoveryShieldActive = false
    } else {
      logger.warning(
        "Recovery shield armed for \(self.recoveringDeletions.count, privacy: .public) un-propagated deletion(s)"
      )
    }
  }

  /// The active shield id-set for the apply path. Awaits the snapshot build so a
  /// fetched change that arrives before the snapshot is ready is still shielded
  /// (race-free). Returns `[]` when no recovery is in progress.
  func activeRecoveryShield() async -> Set<CKRecord.ID> {
    guard isRecoveryShieldActive else { return [] }
    await recoverySnapshotTask?.value
    // Re-check after the suspension: `stop()` may have deactivated the shield
    // (and cleared `recoveringDeletions`) while we were awaiting the build.
    guard isRecoveryShieldActive else { return [] }
    return recoveringDeletions
  }

  /// Releases the whole shield once every recovered deletion has been confirmed
  /// sent (`replayedDeletionsInFlight` emptied by clear-on-confirm) — the
  /// recovery session has settled, so a later legitimate peer re-create of a
  /// (formerly) shielded id upserts normally again. Called from
  /// `clearConfirmedReplayedDeletions`.
  func releaseRecoveryShieldIfSettled() {
    guard isRecoveryShieldActive, replayedDeletionsInFlight.isEmpty else { return }
    isRecoveryShieldActive = false
    recoveringDeletions = []
    recoverySnapshotTask = nil
    logger.info("Recovery shield released — all recovered deletions confirmed")
  }

  /// Partitions fetched saved records into those to apply and those the shield
  /// suppresses (a re-delivered deleted-but-un-propagated record). Pure +
  /// `nonisolated static` so the filter is unit-tested without a live engine.
  nonisolated static func partitionShieldedSaves(
    _ saved: [CKRecord], shield: Set<CKRecord.ID>
  ) -> (toApply: [CKRecord], suppressed: [CKRecord]) {
    guard !shield.isEmpty else { return (saved, []) }
    var toApply: [CKRecord] = []
    var suppressed: [CKRecord] = []
    for record in saved {
      if shield.contains(record.recordID) {
        suppressed.append(record)
      } else {
        toApply.append(record)
      }
    }
    return (toApply, suppressed)
  }
}
