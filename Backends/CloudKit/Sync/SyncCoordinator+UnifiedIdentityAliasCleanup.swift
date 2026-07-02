import Foundation

// One-shot unified identity alias cleanup wiring for `SyncCoordinator`.
// Construction, invocation, and the test hook live here so the lifecycle
// file stays under the 400-line limit.
@MainActor
extension SyncCoordinator {

  // MARK: - Unified Identity Alias Cleanup

  /// Constructs and runs the one-shot alias cleanup that physically deletes
  /// aliased retired `instrument` rows from the shared registry and tombstones
  /// each via a `DeletionJournal` write in the same transaction.
  ///
  /// The cleanup gates itself on its OWN completion flag AND on PR5's
  /// `UnifiedInstrumentIdentityMigration` completion flag, so invoking it
  /// every launch is safe — it is a no-op after the first successful run and
  /// a silent skip when PR5 has not yet completed on this device.
  ///
  /// **Ordering:** Must run AFTER `runUnifiedIdentityMigration()` (so
  /// `alias_of` is set on retired rows before we delete them) and AFTER
  /// `replayDeletionJournal()` (its new journal entries replay on the NEXT
  /// launch — same-launch propagation is deferred, design-sanctioned, and
  /// flagged for `@sync-review`). Must run BEFORE the unsynced backfill scan
  /// so the backfill does not re-queue deleted retired rows for upload.
  func runUnifiedIdentityAliasCleanup() async {
    let cleanup = UnifiedInstrumentIdentityAliasCleanup(
      profileIndexDatabase: containerManager.profileIndexDatabase,
      userDefaults: userDefaults)
    do {
      try await cleanup.run()
    } catch {
      logger.error(
        "Unified identity alias cleanup failed: \(error, privacy: .public)")
    }
  }

  /// Test-only: constructs and runs the alias cleanup exactly as the lifecycle
  /// does, so the wiring can be asserted without dispatching a real
  /// `CKSyncEngine` start.
  func runUnifiedIdentityAliasCleanupForTesting() async {
    await runUnifiedIdentityAliasCleanup()
  }
}
