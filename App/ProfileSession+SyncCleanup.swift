import Foundation

// Sync teardown and the `updateProfile` mutator. Reaches the session's
// module-internal task state (`catalogRefreshTask`, `setUpTask`, etc.) —
// those properties are deliberately module-internal in
// `ProfileSession.swift` so this file can manage their lifecycle.

extension ProfileSession {
  // MARK: - Sync Cleanup

  /// Releases per-profile resources held by the coordinator and tears
  /// down the per-store reactive observation streams. Coordinator-related
  /// work is gated on `coordinator != nil`; task cancellation runs
  /// unconditionally so nil-coordinator builds (preview / some tests) do
  /// not leak `setUpTask` etc. past teardown.
  func cleanupSync(coordinator _: SyncCoordinator?) {
    catalogRefreshTask?.cancel()
    catalogRefreshTask = nil
    cryptoSyncStore?.cancelTimer()
    pragmaOptimizeTask?.cancel()
    pragmaOptimizeTask = nil
    periodicPragmaOptimizeTask?.cancel()
    periodicPragmaOptimizeTask = nil
    setUpTask?.cancel()
    setUpTask = nil

    // Cancel any in-flight cross-store side-effect work
    // (`seedBuiltInCryptoPresets`, the cryptoTokenStore ->
    // `investmentStore.revaluateLoadedPositions` callback). Tasks are
    // append-only, so draining the array empties future iterations.
    for task in crossStoreUpdateTasks {
      task.cancel()
    }
    crossStoreUpdateTasks.removeAll()

    // Tear down reactive observation. MUST run AFTER any GRDB wipes so
    // the empty-state transition reaches subscribed views before the
    // task is cancelled. See `signOutTeardownOrdering` tests across the
    // per-store sync-refresh test suites.
    accountStore.stopObserving()
    earmarkStore.stopObserving()
    accountGroupStore?.stopObserving()
    groupUIStateStore?.stopObserving()
    insightStore?.stopObserving()
    categoryStore.stopObserving()
    importRuleStore.stopObserving()
    transactionStore.stopObserving()
    investmentStore.stopObserving()
  }

  // MARK: - Profile Update

  /// Replaces `self.profile` with an updated copy. Used by the
  /// `SessionManager` bump-on-write path to keep the in-memory value
  /// consistent with what was just persisted to `profile-index.sqlite`.
  /// Identity must not change — the session is keyed on `profile.id`
  /// in `SessionManager.sessions`; an identity swap would orphan the
  /// dictionary entry.
  func updateProfile(_ updated: Profile) {
    precondition(
      updated.id == profile.id,
      "updateProfile must not change identity; the session is keyed on profile.id")
    self.profile = updated
  }
}
