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

/// Classification of the persisted sync-state file by the start-time byte-size
/// gate (issue #1090 / #12).
enum BloatGateOutcome: Sendable, Equatable {
  /// State is absent or below the bloat threshold — the engine starts from it
  /// normally and the recovery attempt count is re-armed (reset to 0).
  case healthy
  /// State exceeded the threshold and recovery was allowed — the engine was
  /// rebuilt with `nil` state (instant init) and self-heals on launch.
  case recovered
  /// State exceeded the threshold but recovery was NOT allowed (attempt ceiling
  /// reached, or iCloud known-unavailable) — the existing state is passed
  /// through (off-main init absorbs the stall) and a warning is logged.
  case bloatedButSkipped
}

// Instance members are `@MainActor` (the shield state they mutate is
// MainActor-isolated); the `nonisolated static` members (the off-actor
// `prepareEngine` + the pure gate / partition helpers) keep their isolation.
@MainActor
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

  /// Durable "recovery incomplete" marker key — set when a recovery had to fail
  /// closed (suppress-all) and may have dropped peer-only records the engine's
  /// change token has since advanced past. Forces a fresh recovery (regardless
  /// of state size) on the next launch to re-deliver them.
  static let recoveryIncompleteMarkerKey = "com.moolah.sync.recoveryIncomplete"

  /// How many times to re-read the journal before giving up and failing closed
  /// — a transient GRDB read error usually clears on a retry, yielding a precise
  /// shield with no drops at all.
  static let recoverySnapshotReadAttempts = 3

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
    forceRecovery: Bool,
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
      stateByteCount: data?.count,
      allowRecovery: allowRecovery,
      forceRecovery: forceRecovery,
      threshold: bloatThreshold)
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
      recoveryOutcome: outcome,
      // Forced (marker-driven) recoveries must NOT count against the normal
      // size-recovery ceiling — they're a separate, self-clearing mechanism.
      recoveryWasForced: forceRecovery && outcome == .recovered)
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
  /// allowed / forced. `forceRecovery` (the durable "recovery incomplete"
  /// marker) wins regardless of size — a prior fail-closed recovery may have
  /// dropped peer-only records the engine's token has advanced past, and only a
  /// fresh nil-reset re-delivers them. Otherwise `nil` byteCount (no state file)
  /// or a below-threshold size is `.healthy`. Pure + `nonisolated static`.
  nonisolated static func bloatGateOutcome(
    stateByteCount: Int?, allowRecovery: Bool, forceRecovery: Bool, threshold: Int
  ) -> BloatGateOutcome {
    if forceRecovery { return .recovered }
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

  /// `true` while a prior recovery failed closed: a fresh recovery is forced on
  /// this launch (regardless of state size, and bypassing the size-recovery
  /// ceiling) to re-deliver any peer-only record dropped under suppress-all.
  /// Gated on entitlements + iCloud-not-known-unavailable like `isRecoveryAllowed`.
  var isRecoveryForced: Bool {
    guard isCloudKitAvailable, recoveryIncomplete else { return false }
    if case .unavailable = iCloudAvailability { return false }
    return true
  }

  /// The durable "recovery incomplete" marker (UserDefaults).
  var recoveryIncomplete: Bool {
    userDefaults.bool(forKey: Self.recoveryIncompleteMarkerKey)
  }

  /// Sets the marker so the next launch forces a fresh recovery — survives the
  /// attempt-ceiling reset (a separate key) so a healthy launch can't swallow it.
  func markRecoveryIncomplete() {
    userDefaults.set(true, forKey: Self.recoveryIncompleteMarkerKey)
  }

  /// Clears the marker once a recovery completed WITHOUT failing closed — the
  /// forced refetch re-delivered and applied any stranded peer record.
  func clearRecoveryIncomplete() {
    userDefaults.removeObject(forKey: Self.recoveryIncompleteMarkerKey)
  }

  // MARK: - Outcome handling (called from completeStart)

  /// Applies the byte-size gate outcome at start: a recovery arms the tombstone
  /// shield (and, unless it was marker-FORCED, bumps the size-recovery ceiling);
  /// a healthy launch re-arms the ceiling; a skipped-but-bloated launch warns
  /// (the existing state runs as-is). A healthy launch does NOT touch the
  /// recovery-incomplete marker — only a clean recovery clears it.
  func applyRecoveryOutcome(_ outcome: BloatGateOutcome, wasForced: Bool) {
    switch outcome {
    case .recovered:
      if !wasForced {
        incrementRecoveryAttemptCount()
      }
      logger.warning(
        "Bloated sync state recovered (\(wasForced ? "forced re-recovery" : "size-gated", privacy: .public)): rebuilt the engine with empty state"
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
    recoveryFetchDidSettle = false
    recoveryShieldSuppressAll = false
    recoveryReplayDidRun = false
    // Cancel any in-flight snapshot from a prior arm before replacing it, so an
    // abandoned build can't resume and overwrite the new snapshot.
    recoverySnapshotTask?.cancel()
    recoverySnapshotTask = Task { [weak self] in
      await self?.buildRecoveryDeletionSnapshot()
    }
  }

  /// Builds `recoveringDeletions` = the union of every journal deletion id
  /// (index DB + each live profile DB), resolved to its real CloudKit zone.
  /// Retries a failed read a few times first (a transient GRDB error usually
  /// clears, yielding a precise shield with no drops), then hands the result to
  /// `applyRecoverySnapshot`.
  private func buildRecoveryDeletionSnapshot() async {
    var resolved: [CKRecord.ID: ReplayedDeletionRef] = [:]
    var readFailed = true
    for attempt in 0..<Self.recoverySnapshotReadAttempts {
      if attempt > 0 {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard !Task.isCancelled else { return }
      let result = await resolveAllJournalDeletions()
      guard !Task.isCancelled else { return }
      resolved = result.resolved
      readFailed = result.readFailed
      if !readFailed { break }
      logger.error(
        "Recovery shield: journal read attempt \(attempt + 1, privacy: .public) of \(Self.recoverySnapshotReadAttempts, privacy: .public) failed"
      )
    }
    applyRecoverySnapshot(resolved: resolved, readFailed: readFailed)
  }

  /// Installs the resolved snapshot. Fail-closed on `readFailed`: the snapshot is
  /// INCOMPLETE, so `recoveryShieldSuppressAll` makes the apply path drop ALL
  /// fetched saves this session (the forced refetch would otherwise resurrect an
  /// un-enumerable deletion) and a durable marker forces a fresh recovery next
  /// launch (the engine advances its token past dropped saves, so a peer-only
  /// record dropped here would otherwise be permanently missing). Reads-OK +
  /// empty journals ⇒ nothing to shield ⇒ deactivate.
  func applyRecoverySnapshot(
    resolved: [CKRecord.ID: ReplayedDeletionRef], readFailed: Bool
  ) {
    recoveringDeletions = Set(resolved.keys)
    recoveryShieldSuppressAll = readFailed
    if readFailed {
      markRecoveryIncomplete()
      logger.error(
        "Recovery shield: journal read failed after \(Self.recoverySnapshotReadAttempts, privacy: .public) attempts — failing closed (suppressing ALL fetched saves) and marking recovery incomplete to force a fresh recovery next launch"
      )
    } else if recoveringDeletions.isEmpty {
      isRecoveryShieldActive = false
    } else {
      logger.warning(
        "Recovery shield armed for \(self.recoveringDeletions.count, privacy: .public) un-propagated deletion(s)"
      )
    }
  }

  #if DEBUG
    /// Test seam: observe the built shield id-set, awaiting the snapshot build
    /// (race-free). The production apply path uses `recoveryShieldedSaves`, which
    /// additionally models the fail-closed suppress-all mode. Guarded by
    /// `#if DEBUG` so it is not part of the shipping API surface.
    func activeRecoveryShield() async -> Set<CKRecord.ID> {
      guard isRecoveryShieldActive else { return [] }
      await recoverySnapshotTask?.value
      guard !Task.isCancelled, isRecoveryShieldActive else { return [] }
      return recoveringDeletions
    }
  #endif

  /// The apply-path entry point: partitions fetched saves into those to apply
  /// and those the recovery shield suppresses. Awaits the snapshot build
  /// (race-free vs the forced refetch). Outside recovery everything applies;
  /// under a read-failed (fail-closed) recovery EVERYTHING is suppressed.
  func recoveryShieldedSaves(
    _ saved: [CKRecord]
  ) async -> (toApply: [CKRecord], suppressed: [CKRecord]) {
    guard isRecoveryShieldActive else { return (saved, []) }
    await recoverySnapshotTask?.value
    // Re-check after the suspension: `stop()` may have deactivated the shield,
    // or the apply task may have been cancelled, while we awaited the build.
    guard !Task.isCancelled, isRecoveryShieldActive else { return (saved, []) }
    if recoveryShieldSuppressAll { return ([], saved) }
    return Self.partitionShieldedSaves(saved, shield: recoveringDeletions)
  }

  /// Releases the whole shield only once the recovery session has fully settled:
  /// every recovered deletion confirmed sent (`replayedDeletionsInFlight`
  /// emptied) AND a full fetch session has completed since arming AND we are not
  /// mid-fetch. The shield MUST outlive the forced token-less refetch —
  /// releasing on delete-confirm alone would let a still-draining refetch
  /// re-deliver (and resurrect) a record whose `.deleteRecord` just propagated.
  /// Called from `clearConfirmedReplayedDeletions` and `endFetchingChanges`.
  func releaseRecoveryShieldIfSettled() {
    guard isRecoveryShieldActive,
      recoveryReplayDidRun,
      replayedDeletionsInFlight.isEmpty,
      recoveryFetchDidSettle,
      !isFetchingChanges
    else { return }
    // A recovery that never failed closed has now applied the full refetch
    // cleanly — clear the durable marker so we don't force another recovery. A
    // suppress-all session leaves the marker set (it may have dropped peer-only
    // records) so the next launch re-recovers.
    if !recoveryShieldSuppressAll {
      clearRecoveryIncomplete()
    }
    isRecoveryShieldActive = false
    recoveringDeletions = []
    recoveryShieldSuppressAll = false
    recoveryFetchDidSettle = false
    recoveryReplayDidRun = false
    recoverySnapshotTask = nil
    logger.info(
      "Recovery shield released — deletions confirmed and the post-recovery refetch has settled")
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
