import Foundation

// One-shot unified cross-chain instrument identity migration wiring for
// `SyncCoordinator`. Construction, invocation, and the test hook live here
// so the lifecycle file stays under the 400-line limit.
@MainActor
extension SyncCoordinator {

  // MARK: - Unified Identity Migration

  /// Constructs and runs the one-shot unified cross-chain instrument identity
  /// migration. Skipped when the shared registry or canonical resolver is absent
  /// (preview / test contexts that never pass these deps). The migration gates
  /// itself on a `UserDefaults` completion flag, so invoking it every launch is
  /// safe — it is a no-op after the first successful run.
  func runUnifiedIdentityMigration() async {
    guard let registry = sharedInstrumentRegistry,
      let resolver = sharedCanonicalResolver
    else { return }
    let migration = UnifiedInstrumentIdentityMigration(
      profileIndexDatabase: containerManager.profileIndexDatabase,
      // `dataDatabaseProvider` is `@MainActor`, so `database(for:)` (a `@MainActor`
      // method) is callable directly — no `assumeIsolated` runtime trap.
      dataDatabaseProvider: { [containerManager] profileId in
        try containerManager.database(for: profileId)
      },
      allProfileIds: { [containerManager] in await containerManager.allProfileIds() },
      registry: registry,
      resolver: resolver,
      rePush: { [weak self] in await self?.queueAllRecordsAfterImport(for: $0) },
      userDefaults: userDefaults)
    do { try await migration.run() } catch {
      logger.error("Unified identity migration failed: \(error, privacy: .public)")
    }
  }
}
