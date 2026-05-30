import Foundation
import GRDB
import SwiftUI

// Scene-phase sync flushing and URL-scheme routing.
extension MoolahApp {

  // MARK: - Background Sync

  func handleScenePhaseChange(_ newPhase: ScenePhase) {
    switch newPhase {
    case .background:
      flushPendingChanges()
      runPragmaOptimizeOnAllSessions()
    case .active:
      // Tracked + cancellable via SyncCoordinator. Rapid scene-phase
      // cycling (e.g. dragging a window across Spaces) can call this
      // repeatedly; the coordinator cancels the prior task before
      // launching a new one so concurrent fetches don't stack.
      logger.info("Fetching remote changes on foreground entry")
      syncCoordinator.scheduleFetchChanges()
    default:
      break
    }
    forwardScenePhaseToSyncStores(newPhase)
  }

  /// Forwards every scenePhase transition to each open profile's
  /// `SyncedAccountStore` so the per-profile timer + scene-active sync
  /// trigger live alongside the rest of the lifecycle plumbing instead
  /// of needing a separate `.onChange` modifier inside the window
  /// hierarchy. Each store handles cancel-then-spawn / cancel-then-clear
  /// internally — see `SyncedAccountStore.handleScenePhaseChange`.
  private func forwardScenePhaseToSyncStores(_ newPhase: ScenePhase) {
    for session in sessionManager.openProfiles {
      session.cryptoSyncStore?.handleScenePhaseChange(newPhase)
    }
  }

  /// Per `guides/DATABASE_SCHEMA_GUIDE.md` §5, the recommended cadence for
  /// `PRAGMA optimize` is "once on app resign-active and at most once per
  /// hour while active". This handler covers the resign-active half by
  /// asking each open session to schedule its own tracked optimize task —
  /// the session stores the handle and cancels it on teardown, so this
  /// loop never leaks fire-and-forget Tasks. It also runs `PRAGMA optimize`
  /// on the app-scoped `profile-index.sqlite` queue (which has no owning
  /// session). The hourly-while-active half is owned by
  /// `ProfileSession.startPeriodicPragmaOptimize(interval:)`, which is
  /// started from the session initialiser.
  func runPragmaOptimizeOnAllSessions() {
    for session in sessionManager.openProfiles {
      session.schedulePragmaOptimize()
    }
    optimizeProfileIndexQueue()
  }

  /// Best-effort synchronous `PRAGMA optimize` on the app-scoped
  /// `profile-index.sqlite` queue. Synchronous because we only run on
  /// resign-active (the OS may suspend us shortly) and `PRAGMA optimize`
  /// completes in milliseconds.
  private func optimizeProfileIndexQueue() {
    do {
      try containerManager.profileIndexDatabase.write { database in
        try database.execute(sql: "PRAGMA optimize")
      }
    } catch {
      logger.warning(
        "PRAGMA optimize failed for profile-index: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func flushPendingChanges() {
    guard syncCoordinator.hasPendingChanges else {
      logger.debug("No pending changes to flush on background entry")
      return
    }

    logger.info("Flushing pending sync changes on background entry")

    #if os(iOS)
      // Request extra background time on iOS to complete uploads.
      // On macOS the app process stays alive, so no special handling is needed.
      ProcessInfo.processInfo.performExpiringActivity(
        withReason: "Uploading pending sync changes"
      ) { expired in
        guard !expired else { return }
        Task { @MainActor in
          await self.syncCoordinator.sendChanges()
        }
      }
    #else
      Task {
        await syncCoordinator.sendChanges()
      }
    #endif
  }

  // MARK: - URL Handling

  /// Routes inbound URLs to the right subsystem:
  ///
  /// - `file://*.csv` — CSV files opened via Finder "Open With Moolah" or
  ///   dropped on the Dock icon. Posted as a notification; the active
  ///   profile's `ContentView` is subscribed and routes it through
  ///   `ImportStore.ingest` (matcher auto-routes, unknown files land in
  ///   Needs Setup) exactly like a drag-and-drop.
  /// - `moolah://…` — deep links from the Safari import extension (and any
  ///   future internal use). Parsed by `DeepLinkRouter` and forwarded to
  ///   `DeepLinkCoordinator`; unparseable URLs are silently dropped.
  func handleURL(_ url: URL) {
    if url.isFileURL {
      guard url.pathExtension.lowercased() == "csv" else { return }
      NotificationCenter.default.post(name: .openCSVFile, object: url)
      return
    }
    if let destination = DeepLinkRouter.parse(url) {
      deepLinkCoordinator.handle(destination)
    }
  }
}
