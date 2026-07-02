// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

import CloudKit
import Foundation
import GRDB
import ImportExtensionKit
import OSLog
import SwiftUI

// Launch-time container/sync/automation configuration. All members are
// static and referenced from `MoolahApp.init()`.
extension MoolahApp {

  struct ContainerSetup {
    let manager: ProfileContainerManager
    let uiTestingProfileId: UUID?
  }

  /// Returns the `UITestSeed` to hydrate from when the process was launched
  /// with `--ui-testing`, or `nil` for normal launches. An unset or unknown
  /// `UI_TESTING_SEED` is a fatal error so test runs cannot silently fall
  /// back to an unrelated seed when the environment fails to propagate.
  static func uiTestingSeed(from arguments: [String]) -> UITestSeed? {
    guard arguments.contains("--ui-testing") else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["UI_TESTING_SEED"] else {
      fatalError(
        "--ui-testing launched without UI_TESTING_SEED — set the env var via MoolahApp.launch(seed:)."
      )
    }
    guard let seed = UITestSeed(rawValue: raw) else {
      fatalError("Unknown UI test seed '\(raw)' — extend UITestSeed in UITestSupport.")
    }
    return seed
  }

  /// Build the `ProfileContainerManager` — either backed by the user's
  /// on-disk profile index or, under UI testing, by an in-memory one
  /// hydrated from the requested seed.
  static func makeContainerSetup(uiTestingSeed: UITestSeed?) -> ContainerSetup {
    do {
      if let seed = uiTestingSeed {
        // Each `--ui-testing` launch starts from a fresh in-memory
        // `ProfileContainerManager` with a different seed, but
        // `UserDefaults.moolahShared` persists across xctest launches in
        // the same runner. `ValuationModeMigration`'s per-profile gate
        // flags would otherwise short-circuit any newer profile that
        // happens to reuse a dead UUID (rare) and — more importantly —
        // leave stale state visible to tests that read
        // `UserDefaults.moolahShared`. Production code paths never enter
        // this branch.
        ValuationModeMigration.resetGateFlags(in: .moolahShared)
        UnifiedInstrumentIdentityMigration.resetGateFlag(in: .moolahShared)
        UnifiedInstrumentIdentityAliasCleanup.resetGateFlag(in: .moolahShared)
        let manager = try ProfileContainerManager.forTesting()
        let profile = try UITestSeedHydrator.hydrate(seed, into: manager)
        return ContainerSetup(manager: manager, uiTestingProfileId: profile?.id)
      }

      let profileIndexURL = URL.moolahScopedApplicationSupport
        .appending(path: "Moolah", directoryHint: .isDirectory)
        .appending(path: "profile-index.sqlite")
      let profileIndexDatabase = try ProfileIndexDatabase.open(at: profileIndexURL)

      let manager = ProfileContainerManager(
        profileIndexDatabase: profileIndexDatabase
      )
      return ContainerSetup(manager: manager, uiTestingProfileId: nil)
    } catch {
      fatalError("Failed to initialize ProfileContainerManager: \(error)")
    }
  }

  /// Wire the sync coordinator to reload profiles on remote changes only
  /// for production launches. Test contexts must not reach for real iCloud:
  ///   - XCTest: the test binary is signed with the production iCloud
  ///     entitlement, so the coordinator would fetch real records from the
  ///     user's iCloud into on-disk profile stores; those records have bled
  ///     into tests' in-memory containers via SwiftData's shared process
  ///     state and caused intermittent balance failures.
  ///   - --ui-testing: the app is running against in-memory `TestBackend`-
  ///     shaped storage and must not reach for real iCloud. See
  ///     guides/UI_TEST_GUIDE.md §6.
  static func configureSyncCoordinator(
    store: ProfileStore,
    coordinator: SyncCoordinator,
    isUITesting: Bool
  ) {
    let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
    let isRunningTests = NSClassFromString("XCTestCase") != nil
    if isUITesting {
      logger.info("Running under --ui-testing — skipping CloudKit sync coordinator")
      return
    }
    if isRunningTests {
      logger.info("Running under XCTest — skipping CloudKit sync coordinator")
      return
    }
    guard CloudKitAuthProvider.isCloudKitAvailable else {
      logger.warning(
        "CloudKit not available — profile sync disabled (NSUbiquitousContainers missing from Info.plist)"
      )
      return
    }
    logger.info("CloudKit available — starting sync coordinator")
    _ = coordinator.addIndexObserver { [weak store] in
      store?.loadCloudProfiles()
    }
    // No launch-time data migration gates the engine start: the local
    // profile index is hydrated synchronously by `ProfileIndexDatabase.open`
    // before the coordinator exists, so `start()` can run immediately.
    // The coordinator owns the spawned `launchTask` so `stop()` can
    // cancel a pending start on early teardown.
    coordinator.startAfter(profileIndexMigration: nil)
    // Clean up the legacy CloudKit zone from SwiftData's automatic sync.
    LegacyZoneCleanup.performIfNeeded()
  }

  /// Apply any `SyncProgress` mutations required by a UI test seed.
  ///
  /// Called immediately after `SyncCoordinator` is created and before
  /// `configureSyncCoordinator` wires any real CloudKit observers. Under
  /// `--ui-testing` the coordinator is never started, so these mutations
  /// are the only writes that drive the progress state seen by the test.
  ///
  /// Seeds that do not need custom progress state are a no-op.
  static func applySeedProgressFixtures(seed: UITestSeed?, coordinator: SyncCoordinator) {
    guard let seed else { return }
    switch seed {
    case .tradeBaseline,
      .welcomeEmpty,
      .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles,
      .cryptoCatalogPreloaded,
      .tradeReady,
      .incompatibleProfile,
      .transferDetectionBaseline,
      .pendingWebImportOneChaseInbox,
      .insightsForYouBaseline:
      break
    case .welcomeDownloading:
      // Override iCloudAvailability to `.available` so the WelcomeStateResolver
      // can reach `.heroDownloading`. Without this, `SyncCoordinator.init` sets
      // `.unavailable(.entitlementsMissing)` in the test environment (no real
      // iCloud entitlement), which routes the resolver to `.heroOff` first.
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.beginReceiving()
      coordinator.progress.recordReceived(modifications: 1234, deletions: 0)
    case .sidebarFooterUpToDate:
      // Override iCloudAvailability so the progress calls are not no-ops.
      // `SyncCoordinator.init` sets `.unavailable(.entitlementsMissing)` in
      // test environments (no real iCloud entitlement), which keeps the
      // progress phase as `.degraded` and blocks `beginReceiving` / `endReceiving`.
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.beginReceiving()
      coordinator.progress.endReceiving(now: Date(timeIntervalSinceNow: -300))
    case .sidebarFooterReceiving:
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.beginReceiving()
      coordinator.progress.recordReceived(modifications: 1234, deletions: 0)
    case .sidebarFooterSending:
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.updatePendingUploads(12)
      coordinator.progress.beginReceiving()
      coordinator.progress.endReceiving(now: Date())
    }
  }

  // Shared-registry plumbing (`bootstrapSyncCoordinator`,
  // `makeSharedInstrumentRegistry`, `makeSharedInstrumentScope`,
  // `attachSharedInstrumentRegistrySyncHooks`) lives in the sibling
  // `MoolahApp+SharedInstrumentScope.swift` file.

  /// Build the `SessionManager` and wire its `onProfileRemoved` cleanup
  /// hook. The hook closure captures the manager and coordinator weakly
  /// so a cleanup hop after profile deletion doesn't keep them alive
  /// past the app's lifetime.
  static func makeSessionManager(
    setup: ContainerSetup, store: ProfileStore, coordinator: SyncCoordinator
  ) -> SessionManager {
    let sessionManager = SessionManager(
      containerManager: setup.manager,
      profileIndexRepository: setup.manager.profileIndexRepository,
      syncCoordinator: coordinator)
    // Wire the mid-session bump-arrival observer: when a remote
    // profile-index batch raises a profile's `dataFormatVersion`
    // above `DataFormatVersion.current`, the observer evicts the
    // active session (if any) and records an `IncompatibleProfileInfo`
    // so routing flips to the incompatible view (issue #764).
    sessionManager.installIndexObserver()
    // Clean up cached sessions and the coordinator's per-profile bundle
    // cache when a profile is removed (locally or via remote sync).
    // `containerManager.deleteStore` is about to invalidate the
    // per-profile `DatabaseQueue`; the coordinator's cached handler /
    // bundle would otherwise outlive it.
    store.onProfileRemoved = { [weak sessionManager, weak coordinator] profileID in
      sessionManager?.removeSession(for: profileID)
      coordinator?.evictCachedState(for: profileID)
      // Drop the deleted profile's queued pending changes so stale saves
      // can't wedge the upload queue (issue #1087). Genuine-deletion path
      // only — never the data-format-incompatibility gate.
      coordinator?.purgePendingChanges(forProfileZone: profileID)
    }
    return sessionManager
  }

  /// Build the deep-link coordinator and the pending-imports banner model
  /// as a pair. Both watch the App Group inbox; the banner's tap closure
  /// drains through the coordinator so a "Review Later" tap shares the
  /// same code path as a `moolah://` URL arriving from the extension.
  ///
  /// Inbox resolution precedence:
  ///   1. `UITestEnvironment.inboxDirectory` env var — set by
  ///      `MoolahApp.launch(seed:)` in UI tests; takes precedence so the
  ///      seed's pre-written fixtures and the banner's reads agree
  ///      regardless of whether the test host happens to resolve a
  ///      Group Container path.
  ///   2. `InboxWriter.shared()` — the App Group container in production
  ///      Release builds.
  ///   3. `PendingImportsBannerFallback.inbox()` — an ephemeral
  ///      per-launch directory that is always empty, so the model
  ///      reports `.none` instead of crashing in Debug builds with no
  ///      App Group entitlement and no UI-test override.
  static func makeDeepLinkAndBannerModel(
    sessionManager: SessionManager
  ) -> (DeepLinkCoordinator, PendingImportsBannerModel) {
    let inbox = resolveInboxWriter()
    let coordinator = DeepLinkCoordinator(
      importStoreProvider: { [sessionManager] in
        sessionManager.sessions.values.first?.importStore
      },
      inboxProvider: { inbox })
    // The closure is `@MainActor`-isolated (matching the model's
    // `onTap` parameter), but `coordinator.handle` is `async`, so a
    // `Task` hop is still required to start it from the synchronous
    // `reviewTapped()` call site. Marking the closure `@MainActor` keeps
    // the `coordinator` capture on-actor so we don't need a separate
    // `@MainActor in` annotation inside.
    let bannerModel = PendingImportsBannerModel(
      writer: inbox,
      onTap: { destination in
        Task { await coordinator.handle(destination) }
      })
    return (coordinator, bannerModel)
  }

  /// Implements the precedence list documented on
  /// `makeDeepLinkAndBannerModel(sessionManager:)`. The same writer
  /// instance is passed to both the banner (read path) and the
  /// deep-link coordinator (drain path) so they cannot disagree on the
  /// inbox root — a Release-config quirk on macOS resolves a Group
  /// Container path even without the entitlement, so the override has
  /// to win over `InboxWriter.shared()` rather than only filling in
  /// when shared returns nil.
  private static func resolveInboxWriter() -> InboxWriter {
    if let override = ProcessInfo.processInfo.environment[UITestEnvironment.inboxDirectory],
      !override.isEmpty
    {
      return InboxWriter(rootDirectory: URL(fileURLWithPath: override))
    }
    return InboxWriter.shared() ?? PendingImportsBannerFallback.inbox()
  }

  /// Configure the automation service locator. On macOS this also sets up
  /// the AppleScript scripting context.
  static func configureAutomationService(
    store: ProfileStore,
    sessionManager: SessionManager,
    containerManager: ProfileContainerManager,
    coordinator: SyncCoordinator
  ) {
    #if os(macOS)
      let automationService = ScriptingContext.configure(
        sessionManager: sessionManager, profileStore: store,
        containerManager: containerManager, syncCoordinator: coordinator)
      AutomationServiceLocator.shared.service = automationService
    #else
      let automationService = AutomationService(sessionManager: sessionManager)
      AutomationServiceLocator.shared.service = automationService
    #endif
  }

  /// One-shot cleanup: removes the obsolete gzipped JSON rate caches
  /// (rate persistence lives in per-profile SQLite). Gated by
  /// the `v2.rates.cache.cleared` `UserDefaults` flag so it runs at most
  /// once per install. Best-effort — failures are silent and the rate
  /// services repopulate from network on demand.
  ///
  /// `defaults` is injected with a `.moolahShared` default so production callers
  /// pass nothing while tests can supply an isolated suite — satisfies the
  /// `CODE_GUIDE.md` §17 "no direct singleton access" rule without
  /// inventing a wrapper type for a single call site.
  static func cleanupLegacyRateCachesOnce(defaults: UserDefaults = .moolahShared) {
    let key = "v2.rates.cache.cleared"
    guard !defaults.bool(forKey: key) else { return }
    let logger = Logger(subsystem: "com.moolah.app", category: "LegacyCacheCleanup")
    if let caches = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)
      .first
    {
      let fileManager = FileManager.default
      for sub in ["exchange-rates", "stock-prices", "crypto-prices"] {
        let url = caches.appendingPathComponent(sub)
        do {
          try fileManager.removeItem(at: url)
        } catch let error as NSError
          where error.domain == NSCocoaErrorDomain
          && error.code == NSFileNoSuchFileError
        {
          // Already absent (e.g. fresh install or prior partial cleanup) — fine.
        } catch {
          logger.warning(
            "Failed to delete legacy rate cache \(sub, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    defaults.set(true, forKey: key)
  }

  /// One-shot cleanup: removes the obsolete SwiftData profile-index and
  /// per-profile data stores (all record types live in GRDB). Gated by
  /// the `v4.swiftDataStores.cleared`
  /// `UserDefaults` flag so it runs at most once per install. Best
  /// effort — a missing file is silent; other failures log at
  /// `.warning` and the flag is still set so we don't retry forever.
  ///
  /// `defaults` is injected with a `.moolahShared` default and
  /// `fileManager` with a `.default` default so production callers pass
  /// nothing while tests can supply isolated stand-ins.
  static func cleanupLegacySwiftDataStoresOnce(
    defaults: UserDefaults = .moolahShared,
    fileManager: FileManager = .default
  ) {
    let key = "v4.swiftDataStores.cleared"
    guard !defaults.bool(forKey: key) else { return }
    let logger = Logger(subsystem: "com.moolah.app", category: "LegacySwiftDataCleanup")
    let appSupport = URL.moolahScopedApplicationSupport
    // Profile-index store ("Moolah-v2.store" + sidecars).
    for suffix in ["", "-shm", "-wal"] {
      let url = appSupport.appending(path: "Moolah-v2.store\(suffix)")
      removeLegacySwiftDataStoreFile(url, fileManager: fileManager, logger: logger)
    }
    // Per-profile data stores ("Moolah-<UUID>.store{,-shm,-wal}").
    if let contents = try? fileManager.contentsOfDirectory(
      at: appSupport, includingPropertiesForKeys: nil)
    {
      for url in contents
      where url.lastPathComponent.hasPrefix("Moolah-")
        && !url.lastPathComponent.hasPrefix("Moolah-v2")
        && (url.lastPathComponent.hasSuffix(".store")
          || url.lastPathComponent.hasSuffix(".store-shm")
          || url.lastPathComponent.hasSuffix(".store-wal"))
      {
        removeLegacySwiftDataStoreFile(url, fileManager: fileManager, logger: logger)
      }
    }
    defaults.set(true, forKey: key)
  }

  private static func removeLegacySwiftDataStoreFile(
    _ url: URL, fileManager: FileManager, logger: Logger
  ) {
    do {
      try fileManager.removeItem(at: url)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && error.code == NSFileNoSuchFileError
    {
      // Already absent — fine.
    } catch {
      logger.warning(
        "Failed to delete legacy SwiftData store \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
