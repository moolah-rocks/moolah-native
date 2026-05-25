#if os(iOS)
  import SwiftUI
  import UIKit

  /// Routes between profile states (iOS only):
  /// - No profiles → WelcomeView (first-run state machine)
  /// - Has active session → SessionRootView
  /// - Loading (session not yet created) → ProgressView
  /// On macOS, ProfileWindowView handles this role.
  struct ProfileRootView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(ProfileContainerManager.self) private var containerManager
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.pendingNavigation) private var pendingNavigationBinding
    @Binding var activeSession: ProfileSession?
    @State private var incompatibleInfo: IncompatibleProfileInfo?

    var body: some View {
      Group {
        // Show WelcomeView for both first-run (no profiles) and the
        // multi-profile picker state (2+ profiles but none active).
        // `activeSession` is only set once the user has explicitly
        // selected a profile, so the else branch naturally handles
        // the picker case.
        if let info = incompatibleInfo {
          IncompatibleProfileView(
            info: info,
            onCheckForUpdates: {
              UIApplication.shared.open(AppStoreURL.update)
            },
            onSwitchProfile: {
              // Pop back to the picker. Clearing the active profile id
              // routes to `WelcomeView` on the next render via the
              // `else` branch; the incompatible state is also cleared
              // so an immediate re-selection re-fires the gate cleanly.
              profileStore.activeProfileID = nil
              activeSession = nil
              incompatibleInfo = nil
            }
          )
        } else if let session = activeSession {
          SessionRootView(session: session)
        } else if profileStore.hasProfiles
          && profileStore.activeProfileID != nil
        {
          // Has an active profile ID but the session hasn't been
          // created yet (cloud store warming up). Brief transient.
          ProgressView()
        } else {
          WelcomeView()
        }
      }
      .onChange(of: profileStore.activeProfileID) { _, newID in
        updateSession(for: newID)
      }
      .onChange(of: profileStore.activeProfile?.label) { _, _ in
        // A rename updates the cached session's profile in place — no
        // teardown, no data reload. `ProfileSession.profile` is
        // `@Observable`, so label-bound UI refreshes off that single
        // assignment without rebuilding the session.
        refreshSessionProfile()
      }
      .onChange(of: profileStore.profiles) { _, _ in
        // Cloud profiles may arrive late (CloudKit not ready at startup).
        // Retry session creation once they appear.
        if activeSession == nil, let id = profileStore.activeProfileID {
          updateSession(for: id)
        }
      }
      .onAppear {
        if activeSession == nil, let id = profileStore.activeProfileID {
          updateSession(for: id)
        }
      }
      .task {
        // Register in-process entry points for App Intents so
        // `OpenAccountIntent` can switch profile / set a pending navigation
        // without going through `UIApplication.shared.open(moolah://…)` —
        // the URL scheme does not exist (issue #386).
        let pendingBinding = pendingNavigationBinding
        let store = profileStore
        NavigationBridge.openProfile = { id in store.setActiveProfile(id) }
        NavigationBridge.setPendingNavigation = { nav in
          pendingBinding?.wrappedValue = nav
        }
      }
      .onContinueUserActivity(HandoffActivity.continueActivityType) { activity in
        guard let payload = activity.handoffPayload else {
          // nil covers both the normal case (unrelated activity, no payload
          // key) and decode failures (logged inside `handoffPayload`).
          return
        }
        HandoffContinuationHandler.continue(payload: payload)
      }
    }

    private func updateSession(for profileID: UUID?) {
      guard let profileID,
        let profile = profileStore.profiles.first(where: { $0.id == profileID })
      else {
        activeSession = nil
        incompatibleInfo = nil
        return
      }

      // Only create a new session if profile changed
      if activeSession?.profile.id != profileID {
        Task {
          let result = await sessionManager.session(for: profile)
          applyOpenResult(result)
        }
      }
    }

    /// Propagates a metadata edit (e.g. label changed in Settings)
    /// into the live session in place. No teardown — the session is
    /// `@Observable`, so label-bound UI updates off the assignment.
    /// Remote `dataFormatVersion` bumps that could make the profile
    /// incompatible are handled separately by `SessionManager`'s index
    /// observer, so a rename must not rebuild the session.
    private func refreshSessionProfile() {
      guard let profile = profileStore.activeProfile else { return }
      sessionManager.refreshProfile(profile)
    }

    private func applyOpenResult(_ result: SessionOpenResult) {
      switch result {
      case .ready(let session):
        activeSession = session
        incompatibleInfo = nil
      case .incompatible(let info):
        activeSession = nil
        incompatibleInfo = info
      }
    }

  }

#endif
