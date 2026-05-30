#if os(macOS)
  import OSLog
  import SwiftUI

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileWindowView")

  /// macOS window content for a single profile.
  /// Each window receives a Profile.ID from `WindowGroup(for:)` and resolves it to a session.
  struct ProfileWindowView: View {
    let profileID: Profile.ID?
    @Environment(ProfileStore.self) private var profileStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pendingNavigation) private var pendingNavigationBinding

    @Environment(\.dismiss) private var dismiss

    @State private var sessionResult: SessionOpenResult?

    /// The `NSWindow` this view is hosted in, captured by `tagHostingWindow`
    /// via `WindowAccessor`. Used by `resolvedProfile` and
    /// `nilBindingIsRedundant` to exclude self when scanning `NSApp.windows`
    /// for sibling profile windows — without this, once `tagHostingWindow`
    /// stamps our identifier the checks would find *us*, decide we're a
    /// duplicate of ourselves, and dismiss the live window.
    @State private var hostingWindow: NSWindow?

    /// Resolve the profile to display: the window's profileID if it matches a
    /// known profile, otherwise the active profile, otherwise the single
    /// profile when exactly one exists.
    ///
    /// The two fallback branches (`activeProfileID`, `profiles.count == 1`)
    /// only fire when this window has no value binding — i.e. a nil-binding
    /// window restored from prior SwiftUI scene state, or one opened
    /// without a value. If another NSWindow is already tagged with the
    /// candidate profile's identifier, the fallback returns `nil` so the
    /// nil-binding window doesn't shadow its sibling. The body's WelcomeView
    /// branch then dismisses the redundant window via `nilBindingIsRedundant`.
    /// Without this guard the same profile would render in two windows
    /// after every launch.
    private var resolvedProfile: Profile? {
      if let profileID,
        let profile = profileStore.profiles.first(where: { $0.id == profileID })
      {
        return profile
      }
      let fallback = fallbackProfile()
      if let fallback,
        let owner = ProfileWindowLocator.existingWindow(for: fallback.id, in: NSApp.windows),
        owner !== hostingWindow
      {
        return nil
      }
      return fallback
    }

    /// Pure fallback resolution split out so `resolvedProfile` applies
    /// the duplicate-window guard uniformly to both branches.
    private func fallbackProfile() -> Profile? {
      if let activeID = profileStore.activeProfileID,
        let profile = profileStore.profiles.first(where: { $0.id == activeID })
      {
        return profile
      }
      return profileStore.profiles.count == 1 ? profileStore.profiles.first : nil
    }

    /// `true` when this nil-binding window has no profile to show *and*
    /// another window already presents a profile-bound view — the
    /// classic duplicate-after-state-restoration shape. Drives `dismiss()`
    /// in the WelcomeView branch of `body` so the redundant window goes
    /// away instead of lingering on a Welcome screen beside the real one.
    /// Excludes `hostingWindow` so a window that has tagged itself does
    /// not count itself as a sibling.
    private var nilBindingIsRedundant: Bool {
      profileID == nil
        && !profileStore.profiles.isEmpty
        && ProfileWindowLocator.anyOtherProfileWindowPresent(
          excluding: hostingWindow, in: NSApp.windows)
    }

    var body: some View {
      Group {
        if let resolved = resolvedProfile {
          sessionContent(for: resolved)
        } else if profileID != nil {
          // This window was opened for a specific profile that does not
          // exist. Close it — the user will land on whichever window
          // SwiftUI brings forward next.
          Color.clear
            .onAppear {
              logger.warning(
                "Dismissing window — profile not found. profileID=\(profileID?.uuidString ?? "nil", privacy: .public), profileCount=\(profileStore.profiles.count), profileIDs=\(profileStore.profiles.map(\.id).map(\.uuidString).joined(separator: ","), privacy: .public)"
              )
              dismiss()
            }
        } else if nilBindingIsRedundant {
          // State restoration brought back a nil-binding window beside a
          // value-bound one for the same profile (the "two windows for
          // one profile" shape). Drop the redundant window — the user
          // keeps the explicit profile-bound window.
          Color.clear
            .onAppear {
              logger.info(
                "Dismissing redundant nil-binding window — profile-bound window already on screen"
              )
              dismiss()
            }
        } else {
          // No specific profile requested AND no active profile. Covers
          // both the empty first-run case (`!hasProfiles` → hero state 1)
          // and the multi-profile-no-selection case (2+ profiles, none
          // picked → picker state 5). `WelcomeView`'s state machine
          // picks the right branch.
          //
          // On first-profile creation, dismiss *this* nil-binding window
          // after opening the profile-bound one. Otherwise the original
          // Welcome window stays on screen and `resolvedProfile` falls
          // back to the new single profile, producing the duplicate.
          WelcomeView()
            .onChange(of: profileStore.profiles) { _, newProfiles in
              if newProfiles.count == 1, let first = newProfiles.first {
                ProfileWindowLocator.openOrActivate(first.id, openWindow: openWindow)
                dismiss()
              }
            }
        }
      }
      .background(tagHostingWindow)
      .task(id: resolvedProfile?.id) {
        // Resolve the session for the resolved profile. `.task(id:)`
        // re-runs whenever the profile id changes (window reopened
        // against a different profile, or the active profile flips
        // mid-session).
        if let profile = resolvedProfile {
          sessionResult = await sessionManager.session(for: profile)
        } else {
          sessionResult = nil
        }
      }
      .onChange(of: resolvedProfile?.label) { _, _ in
        // A rename updates the cached session's profile in place — no
        // teardown, no data reload. `ProfileSession.profile` is
        // `@Observable`, so label-bound UI refreshes off that single
        // assignment. Remote `dataFormatVersion` bumps that could make
        // the profile incompatible are handled separately by
        // `SessionManager`'s index observer, so the rename path must
        // not rebuild the session.
        guard let profile = resolvedProfile else { return }
        sessionManager.refreshProfile(profile)
      }
      .task {
        // Register in-process entry points for AppleScript/App Intents so
        // `NavigateCommand` / `OpenAccountIntent` don't need to round-trip
        // through `NSWorkspace.shared.open(moolah://…)` — SwiftUI's
        // auto-spawn of a stray window on URL events (issue #378). The
        // URL scheme does not exist (issue #386), so in-process is the
        // only path.
        let openAction = openWindow
        let pendingBinding = pendingNavigationBinding
        NavigationBridge.openProfile = { id in openAction(value: id) }
        NavigationBridge.setPendingNavigation = { nav in
          pendingBinding?.wrappedValue = nav
        }
      }
    }

    /// Renders the per-session content area: the live session, the
    /// stop-the-world incompatible-profile screen, or a brief progress
    /// indicator while the open is in flight.
    @ViewBuilder
    private func sessionContent(for resolved: Profile) -> some View {
      switch sessionResult {
      case .ready(let session):
        SessionRootView(session: session)
          .environment(profileStore)
      case .incompatible(let info):
        IncompatibleProfileView(
          info: info,
          onCheckForUpdates: {
            NSWorkspace.shared.open(AppStoreURL.update)
          },
          onSwitchProfile: {
            // Pop back to the picker. Clearing the active profile
            // routes to `WelcomeView` on the next render via the
            // top-level `else` branch; closing this window also
            // returns the user to whichever window SwiftUI brings
            // forward.
            if profileStore.activeProfileID == resolved.id {
              profileStore.activeProfileID = nil
            }
            dismiss()
          }
        )
      case .none:
        ProgressView()
      }
    }

    /// Stamps the hosting `NSWindow.identifier` with a per-profile identifier
    /// so `ProfileWindowLocator` can find and focus the window when
    /// AppleScript or an App Intent opens a profile that is already on
    /// screen. Also enforces the one-window-per-profile invariant by
    /// closing this window when another window is already tagged for the
    /// resolved profile, and maximises the window under UI testing.
    @ViewBuilder private var tagHostingWindow: some View {
      if let profile = resolvedProfile {
        WindowAccessor { window in
          // Capture the hosting window so `resolvedProfile` and
          // `nilBindingIsRedundant` can exclude self when scanning
          // siblings. Without this they would later find this window's
          // own identifier and dismiss the live window as a "duplicate
          // of itself."
          if hostingWindow !== window {
            hostingWindow = window
          }
          let identifier = ProfileWindowLocator.identifier(for: profile.id)
          // Load-bearing duplicate-window guard. Catches every dup
          // regardless of how it was created: SwiftUI scene-state
          // restoration of a stale window from a prior version, a
          // racing `openWindow(value:)` that slipped past
          // `ProfileWindowLocator.openOrActivate`, even Cmd-N if AppKit
          // ever auto-opens a nil-bound window. The losing window
          // closes via the next runloop turn — closing from inside
          // `viewDidMoveToWindow` would tear down our own host view
          // mid-callback.
          if let existing = ProfileWindowLocator.duplicateWindow(
            for: profile.id, currentWindow: window, in: NSApp.windows)
          {
            logger.warning(
              "Closing duplicate window for profileID=\(profile.id, privacy: .public)"
            )
            existing.makeKeyAndOrderFront(nil)
            Task { @MainActor in
              window.close()
            }
            return
          }
          window.identifier = identifier
          // CI runs on a 1024×768 macos-26 display. The Brokerage-view
          // inspector then renders ~217pt tall — not enough to fit the
          // trade-mode form, so `Received` falls below the visible scroll
          // viewport and stays non-hittable. Maximising the window on
          // UI-test launches gives the inspector the ~450pt it needs.
          // `isRestorable = false` blocks AppKit from overwriting the
          // explicit frame with a remembered one from a prior session.
          // Reading `CommandLine.arguments` here (rather than threading
          // `MoolahApp.isUITesting` down) keeps the read local; if the
          // `--ui-testing` argument grows a second consumer that disagrees
          // with `MoolahApp.uiTestingSeed != nil`, this site will need to
          // be revisited.
          if Self.isUITestingLaunch, let screen = window.screen {
            window.isRestorable = false
            window.setFrame(screen.visibleFrame, display: true)
          }
        }
      }
    }

    /// `true` when the process was launched with `--ui-testing`. Process-
    /// wide and immutable for the lifetime of the launch.
    private static let isUITestingLaunch: Bool =
      CommandLine.arguments.contains("--ui-testing")

  }

#endif
