// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

import CloudKit
import OSLog
import SwiftUI

// Command-menu definitions live in `MoolahDomainCommands.swift`.

@main
@MainActor
struct MoolahApp: App {
  @Environment(\.scenePhase) private var scenePhase
  // internal (was private) so the `+Lifecycle` extension can use these in
  // scene-phase / URL-scheme handlers.
  let containerManager: ProfileContainerManager
  let syncCoordinator: SyncCoordinator
  /// The seeded profile ID under `--ui-testing`, or `nil` for production
  /// launches. Stored as `let` because `MoolahApp.init` runs once per
  /// process; the value is decided at launch and never changes.
  private let uiTestingProfileId: UUID?
  /// True when the process was launched with `--ui-testing`, regardless of
  /// whether the seed hydrates a profile. Welcome-view seeds intentionally
  /// leave `uiTestingProfileId` unset (see `UITestSeedHydrator`) so we also
  /// need a seed-agnostic flag to drive launcher presentation.
  private let isUITesting: Bool
  /// Stable identifier for the primary `WindowGroup(for:)`. Exposed so
  /// `UITestingLauncherView` can call `openWindow(id:)` to open a default
  /// instance with a nil binding — `ProfileWindowView` resolves the
  /// seeded profile (or falls back to `WelcomeView`) on its own.
  static let mainWindowID = "profile-window"
  @State var profileStore: ProfileStore
  // internal (was private) so `+Lifecycle` can log under the shared
  // subsystem/category.
  let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
  @State var pendingNavigation: PendingNavigation?

  #if os(macOS)
    @NSApplicationDelegateAdaptor(ScriptingBridge.self) var scriptingBridge
    private let backupManager: StoreBackupManager
    // internal so `+Lifecycle` can iterate open sessions for
    // `PRAGMA optimize` on resign-active.
    @State var sessionManager: SessionManager
  #else
    @State private var activeSession: ProfileSession?
    // internal so `+Lifecycle` can iterate open sessions for
    // `PRAGMA optimize` on resign-active.
    @State var sessionManager: SessionManager
  #endif

  init() {
    // Anchor the upcoming-card first-paint timer at process start. Without
    // this eager reference, the tracker's `launchTime` lazy global only
    // initializes when the view first reads it (after the data has loaded),
    // making the measured elapsed time uselessly close to zero. See
    // `plans/2026-04-27-upcoming-card-cold-load-plan.md`.
    UpcomingFirstPaintTracker.anchorLaunchTime()

    // UI-testing launch mode: swap the on-disk profile index for an
    // in-memory one and hydrate it from UI_TESTING_SEED. CloudKit sync and
    // telemetry are skipped entirely — the app runs against `TestBackend`
    // shaped storage (in-memory `CloudKitBackend`) so XCUITest flows never
    // touch the user's iCloud. See guides/UI_TEST_GUIDE.md §6.
    let uiTestingSeed = Self.uiTestingSeed(from: CommandLine.arguments)

    // One-shot removal of the obsolete `Caches/{exchange,stock,crypto}`
    // JSON cache directories; rate caches live in per-profile SQLite.
    // Skipped under UI testing where `Caches` is shared with the host
    // user's account and we must not mutate it.
    if uiTestingSeed == nil {
      Self.cleanupLegacyRateCachesOnce()
      Self.cleanupLegacySwiftDataStoresOnce()
    }
    let setup = Self.makeContainerSetup(uiTestingSeed: uiTestingSeed)

    // Build the app-level shared instrument registry + market-data
    // services pointed at the profile-index DB, construct the
    // SyncCoordinator, and rotate the registry's sync hooks in. See
    // MoolahApp+Setup for details.
    let coordinator = Self.bootstrapSyncCoordinator(setup: setup)
    containerManager = setup.manager
    syncCoordinator = coordinator
    uiTestingProfileId = setup.uiTestingProfileId
    isUITesting = uiTestingSeed != nil
    Self.applySeedProgressFixtures(seed: uiTestingSeed, coordinator: coordinator)

    // UI-testing mode must NOT read the user's real UserDefaults; remote
    // profiles are persisted there by `ProfileStore.loadFromDefaults` and
    // would bleed into the seeded container otherwise. A per-launch
    // suite gives the store an isolated, ephemeral defaults store.
    let storeDefaults: UserDefaults
    if uiTestingSeed != nil {
      let suiteName = "com.moolah.ui-testing.\(UUID().uuidString)"
      storeDefaults = UserDefaults(suiteName: suiteName) ?? .standard
      storeDefaults.removePersistentDomain(forName: suiteName)
    } else {
      storeDefaults = .moolahShared
    }
    let store = ProfileStore(
      defaults: storeDefaults,
      containerManager: setup.manager,
      syncCoordinator: coordinator
    )
    _profileStore = State(initialValue: store)

    Self.configureSyncCoordinator(
      store: store,
      coordinator: coordinator,
      isUITesting: uiTestingSeed != nil)

    let sessionManager = Self.makeSessionManager(
      setup: setup, store: store, coordinator: coordinator)
    Self.configureAutomationService(
      store: store,
      sessionManager: sessionManager,
      containerManager: setup.manager,
      coordinator: coordinator)

    #if os(macOS)
      backupManager = StoreBackupManager()
    #endif
    _sessionManager = State(initialValue: sessionManager)
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup(id: Self.mainWindowID, for: Profile.ID.self) { $profileID in
        // UI-testing mode pins the window to the seeded profile; the
        // per-window binding is used only in production launches.
        ProfileWindowView(profileID: uiTestingProfileId ?? profileID)
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .environment(\.pendingNavigation, $pendingNavigation)
          .onOpenURL { url in handleURL(url) }
          .task {
            // Daily backup runs in production launches only; under UI
            // testing the fixture container is ephemeral, so there is
            // nothing meaningful to back up.
            guard uiTestingProfileId == nil else { return }
            await backupManager.performDailyBackup(
              profiles: profileStore.profiles,
              containerManager: containerManager
            )
            // Cancellation-aware loop instead of `Timer.scheduledTimer`,
            // which would outlive the `.task` body and leak when the
            // window goes away. SwiftUI cancels this `.task` on view
            // disappearance, so the sleep throws and the loop exits.
            while !Task.isCancelled {
              try? await Task.sleep(for: .seconds(86400))
              guard !Task.isCancelled else { break }
              await backupManager.performDailyBackup(
                profiles: profileStore.profiles,
                containerManager: containerManager
              )
            }
          }
      }
      // Opt out of SwiftUI's external-event auto-spawn. `WindowGroup(for:)`
      // listens to incoming `NSUserActivity` continuations on a channel
      // that is independent of `NSApplicationDelegate.application(_:continue:)`
      // — returning `true` from the delegate signals AppKit but does NOT
      // suppress this channel, so without the opt-out every Handoff
      // continuation spawns a second window behind the active one
      // (`#386`). Handoff payloads are routed in-process through
      // `ScriptingBridge.application(_:continue:)` → `HandoffContinuationHandler`
      // → `NavigationBridge`, so the WindowGroup never needs to handle
      // external events itself. `UITestingLauncherView` deliberately uses
      // `openWindow(id:)` rather than `openWindow(value:)` because the
      // empty match set also blocks cross-scene `openWindow(value:)`
      // routing into this group.
      .handlesExternalEvents(matching: [])
      // Opt out of NSWindow state restoration under `--ui-testing` so a
      // stale window from a previous test (e.g. one that ended on the
      // Analysis view with a CancellationError) cannot get restored into
      // the next test's launch as a phantom second window. Production
      // launches keep the default `.automatic` behaviour.
      .restorationBehavior(isUITesting ? .disabled : .automatic)
      .onChange(of: scenePhase) { _, newPhase in
        handleScenePhaseChange(newPhase)
      }
      .commands {
        AboutCommands()
        ProfileCommands(
          profileStore: profileStore, sessionManager: sessionManager,
          containerManager: containerManager, syncCoordinator: syncCoordinator)
        NewItemCommands()
        ImportCSVCommands()
        RefreshCommands()
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()
        ViewMenuToggleCommands()
        MoolahDomainCommands()
      }

      Window("About Moolah", id: "about") {
        AboutView()
      }
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)

      Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
        KeyboardShortcutsView()
      }
      .windowResizability(.contentSize)

      Settings {
        SettingsView()
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
      }
      .windowResizability(.contentMinSize)

      // Auto-open the main window on `--ui-testing` launches.
      // `WindowGroup(for: Profile.ID.self)` does not present without an
      // explicit value, so a hidden launcher Window with
      // `.defaultLaunchBehavior(.presented)` calls `openWindow(…)` and
      // immediately dismisses itself. Presented for every UI-testing launch
      // — including Welcome seeds that leave `uiTestingProfileId` nil, so
      // `WelcomeView` still gets a window to render into. Suppressed in
      // production, where normal scene restoration opens the window.
      Window("UI Testing Launcher", id: "ui-testing-launcher") {
        UITestingLauncherView()
      }
      .windowResizability(.contentSize)
      .defaultLaunchBehavior(isUITesting ? .presented : .suppressed)
    #else
      WindowGroup {
        ProfileRootView(activeSession: $activeSession)
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .environment(\.pendingNavigation, $pendingNavigation)
          .onOpenURL { url in handleURL(url) }
      }
      .onChange(of: scenePhase) { _, newPhase in
        handleScenePhaseChange(newPhase)
      }
      .commands {
        NewItemCommands()
        RefreshCommands()
        ViewMenuToggleCommands()
      }
    #endif
  }

}
