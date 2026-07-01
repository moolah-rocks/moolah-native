@preconcurrency import CloudKit
import Foundation
import OSLog

extension SyncCoordinator {
  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  ///
  /// Bundle resolution is delegated to `resolveGRDBRepositories(for:)`, which
  /// returns a cached bundle if one was built before, or constructs a fresh
  /// apply-path bundle via `ProfileGRDBRepositories.makeForApply` backed
  /// by `containerManager.database(for:)`. This allows sync apply for
  /// un-sessionized profiles (multi-profile background apply, pre-render race,
  /// encrypted reset on an unopened profile) — the scenario that motivated
  /// issue #619.
  func handlerForProfileZone(
    profileId: UUID, zoneID: CKRecordZone.ID
  ) throws -> ProfileDataSyncHandler {
    if let existing = dataHandlers[profileId] {
      return existing
    }
    let grdbRepositories = try resolveGRDBRepositories(for: profileId)
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      grdbRepositories: grdbRepositories,
      canonicalResolver: sharedCanonicalResolver)
    dataHandlers[profileId] = handler
    return handler
  }

  /// Returns the per-profile GRDB repository bundle, constructing and caching
  /// it on first access. The bundle is built via
  /// `ProfileGRDBRepositories.makeForApply` backed by
  /// `containerManager.database(for:)`, which allows sync apply for
  /// un-sessionized profiles — see issue #619.
  ///
  /// **Main-actor I/O.** First-access resolution opens the per-profile
  /// `DatabaseQueue` synchronously on `@MainActor`. The work is bounded
  /// (queue init + idempotent schema migration) and only happens once
  /// per profile per process. Moving it off-actor would require
  /// `ProfileContainerManager` to expose async open methods — a
  /// separate refactor.
  private func resolveGRDBRepositories(for profileId: UUID) throws -> ProfileGRDBRepositories {
    if let cached = cachedGRDBRepositories[profileId] {
      return cached
    }
    let database = try containerManager.database(for: profileId)
    // Production CloudKit sync always carries `sharedInstrumentRegistry`
    // (the profile-index registry); the apply bundle's resolver /
    // registrar must therefore target it. There is no per-profile
    // `instrument` table. Tests that build a `SyncCoordinator` without injecting a
    // shared registry fall back to a registry over the container's own
    // profile-index DB — still the shared, account-scoped table, never
    // the per-profile one. The apply path never invokes the
    // resolver / registrar seam (it writes raw Rows), so the fallback
    // registry is correct-by-construction even though it is unseeded.
    let sharedRegistry =
      sharedInstrumentRegistry
      ?? GRDBInstrumentRegistryRepository(
        database: containerManager.profileIndexDatabase)
    let bundle = ProfileGRDBRepositories.makeForApply(
      database: database, sharedRegistry: sharedRegistry)
    cachedGRDBRepositories[profileId] = bundle
    return bundle
  }

  // No per-profile `instrumentRemoteChangeCallbacks` registry exists:
  // the shared registry on the profile-index zone drives every
  // InstrumentRecord remote-change fan-out via
  // `SyncCoordinator.makeInstrumentRemoteChangeFanOut`.

  /// Drops the cached handler and GRDB repository bundle for a profile
  /// being removed locally. The coordinator's caches retain
  /// `DatabaseQueue` references which `ProfileContainerManager.deleteStore`
  /// is about to invalidate; without this eviction a delayed sync event
  /// for the deleted profile would write through a stale queue against
  /// an unlinked file.
  func evictCachedState(for profileId: UUID) {
    dataHandlers.removeValue(forKey: profileId)
    cachedGRDBRepositories.removeValue(forKey: profileId)
  }

  /// Removes every pending change queued for a deleted profile's data zone
  /// (issue #1087 — root prevention of the upload-queue wedge).
  /// Profile deletion tears down the per-profile DB/zone, but the profile's
  /// already-queued `.saveRecord`s would otherwise linger in engine state
  /// forever: their local rows are gone, so every batch build misses them
  /// (`built=0`) and the dead head re-selects each cycle, starving uploads.
  ///
  /// **Call ONLY from the genuine-deletion path** (`onProfileRemoved`), never
  /// from the data-format-incompatibility gate (`SessionManager`), where the
  /// profile still exists locally and on the server — dropping its pending
  /// edits there would lose unsynced user data. That gate uses
  /// `evictCachedState` (cache only); this purge is deliberately separate.
  func purgePendingChanges(forProfileZone profileId: UUID) {
    guard let syncEngine else { return }
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let stale = Self.pendingChanges(
      syncEngine.state.pendingRecordZoneChanges, inZone: zoneID)
    guard !stale.isEmpty else { return }
    logger.warning(
      "Purging \(stale.count, privacy: .public) pending change(s) for deleted profile \(profileId, privacy: .public)"
    )
    syncEngine.state.remove(pendingRecordZoneChanges: stale)
    refreshPendingUploadsMirror()
  }

  /// Removes the per-profile `ProfileDataSyncHandler` from `dataHandlers`.
  /// Called by `SessionManager` on mid-session teardown when a remote bump
  /// pushes the profile's `dataFormatVersion` above
  /// `DataFormatVersion.current`, so `SyncCoordinator` stops routing
  /// further fetched changes for the per-profile zone — see
  /// data-format-gate spec §4.2.
  ///
  /// Idempotent; a no-op for an unknown profile id.
  func removeDataHandler(for profileId: UUID) {
    dataHandlers.removeValue(forKey: profileId)
  }

  #if DEBUG
    /// Test-only: report whether a handler is currently registered for the
    /// given profile id. Guarded by `#if DEBUG` so it is not part of the
    /// production API surface.
    func hasDataHandler(forProfile profileId: UUID) -> Bool {
      dataHandlers[profileId] != nil
    }
  #endif
}
