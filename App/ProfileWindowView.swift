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

    /// Resolve the profile to display: the window's profileID if it matches a
    /// known profile, otherwise the active profile. Falls back to the single
    /// profile only when exactly one exists — with 2+ profiles and nothing
    /// selected, `WelcomeView` shows its picker (state 5) instead of
    /// silently opening one of them.
    private var resolvedProfile: Profile? {
      if let profileID,
        let profile = profileStore.profiles.first(where: { $0.id == profileID })
      {
        return profile
      }
      if let activeID = profileStore.activeProfileID,
        let profile = profileStore.profiles.first(where: { $0.id == activeID })
      {
        return profile
      }
      return profileStore.profiles.count == 1 ? profileStore.profiles.first : nil
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
        } else {
          // No specific profile requested AND no active profile. Covers
          // both the empty first-run case (`!hasProfiles` → hero state 1)
          // and the multi-profile-no-selection case (2+ profiles, none
          // picked → picker state 5). `WelcomeView`'s state machine
          // picks the right branch.
          WelcomeView()
            .onChange(of: profileStore.profiles) { _, newProfiles in
              if newProfiles.count == 1, let first = newProfiles.first {
                openWindow(value: first.id)
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
    /// screen. Also maximises the window and opts out of per-window state
    /// restoration under UI testing — see the inline comment for the
    /// motivating layout race.
    @ViewBuilder private var tagHostingWindow: some View {
      if let profile = resolvedProfile {
        WindowAccessor { window in
          window.identifier = ProfileWindowLocator.identifier(for: profile.id)
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
