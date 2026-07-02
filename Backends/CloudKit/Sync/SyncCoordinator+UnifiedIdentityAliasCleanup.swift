import Foundation

// Construction, invocation, and test hook for unified identity alias cleanup.
@MainActor
extension SyncCoordinator {

  // MARK: - Unified Identity Alias Cleanup

  /// Constructs and runs the one-shot alias cleanup that physically deletes
  /// aliased retired `instrument` rows from the shared registry and tombstones
  /// each via a `DeletionJournal` write in the same transaction.
  ///
  /// The cleanup gates itself on its OWN completion flag AND on
  /// `UnifiedInstrumentIdentityMigration`'s completion flag, so invoking it
  /// every launch is safe — it is a no-op after the first successful run and
  /// a silent skip when the identity migration has not yet completed on this
  /// device.
  ///
  /// **Ordering:** Must run AFTER `runUnifiedIdentityMigration()` (so
  /// `alias_of` is set on retired rows before we delete them). Must run
  /// BEFORE the unsynced backfill scan so the backfill does not re-queue
  /// deleted retired rows for upload. Same-launch tombstone propagation is
  /// achieved by a second `replayDeletionJournal()` call immediately after
  /// this cleanup.
  func runUnifiedIdentityAliasCleanup() async {
    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: containerManager.profileIndexDatabase,
      userDefaults: userDefaults)
    do {
      let deletedCount = try await cleanup.run()
      if deletedCount > 0 {
        sharedInstrumentRegistry?.invalidateInstrumentMapCache()
        sharedInstrumentRegistry?.notifyExternalChange()
      }
    } catch {
      logger.error(
        "Unified identity alias cleanup failed: \(error, privacy: .public)")
    }
  }

  /// Test-only: constructs and runs the alias cleanup exactly as the lifecycle
  /// does, so the wiring can be asserted without dispatching a real
  /// `CKSyncEngine` start.
  #if DEBUG
    func runUnifiedIdentityAliasCleanupForTesting() async {
      await runUnifiedIdentityAliasCleanup()
    }
  #endif
}
