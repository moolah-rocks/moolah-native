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
    @State private var incompatibleProfileID: UUID?

    private var displayedIncompatibility: IncompatibleProfileInfo? {
      guard let profileID = profileStore.activeProfileID else { return nil }
      let cached: SessionOpenResult? =
        (incompatibleProfileID == profileID ? incompatibleInfo : nil)
        .map(SessionOpenResult.incompatible)
        ?? activeSession.map(SessionOpenResult.ready)
      if case .incompatible(let info) = sessionManager.displayedOpenResult(
        profileID: profileID,
        cached: cached)
      {
        return info
      }
      return nil
    }

    var body: some View {
      Group {
        // Show WelcomeView for both first-run (no profiles) and the
        // multi-profile picker state (2+ profiles but none active).
        // `activeSession` is only set once the user has explicitly
        // selected a profile, so the else branch naturally handles
        // the picker case.
        if let info = displayedIncompatibility {
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
        } else if let session = activeSession, session.profile.id == profileStore.activeProfileID {
          SessionRootView(session: session)
        } else if profileStore.hasProfiles
          && profileStore.activeProfileID != nil
        {
          // Has an active profile ID but the session hasn't been
          // created yet (cloud store warming up). Brief transient.
          ProgressView("Opening profile…")
        } else {
          WelcomeView()
        }
      }
      .task(id: profileStore.activeProfile?.id) {
        await updateSession()
      }
      .onChange(of: profileStore.activeProfile) { _, _ in
        // Metadata changes update the cached session's profile in place — no
        // teardown, no data reload. This covers renames and default tax-owner
        // changes; remote `dataFormatVersion` incompatibility is handled by
        // `SessionManager`'s index observer.
        refreshSessionProfile()
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

    private func updateSession() async {
      activeSession = nil
      incompatibleInfo = nil
      incompatibleProfileID = nil
      guard let profile = profileStore.activeProfile else { return }
      let result = await sessionManager.session(for: profile)
      guard !Task.isCancelled, profileStore.activeProfileID == profile.id else { return }
      incompatibleProfileID = profile.id
      let displayed = sessionManager.displayedOpenResult(profileID: profile.id, cached: result)
      applyOpenResult(displayed ?? .cancelled)
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
      case .cancelled:
        activeSession = nil
        incompatibleInfo = nil
        incompatibleProfileID = nil
        profileStore.activeProfileID = nil
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
