#if os(macOS)
  import SwiftUI

  /// macOS File menu commands for opening profile windows, import/export, and signing out.
  struct ProfileCommands: Commands {
    let profileStore: ProfileStore
    let sessionManager: SessionManager
    let containerManager: ProfileContainerManager
    let syncCoordinator: SyncCoordinator

    @FocusedValue(\.authStore) private var authStore
    @FocusedValue(\.activeProfileSession) private var session

    var body: some Commands {
      CommandGroup(before: .saveItem) {
        OpenProfileMenu(profileStore: profileStore)

        Divider()

        ExportImportButtons(
          profileStore: profileStore,
          containerManager: containerManager,
          syncCoordinator: syncCoordinator,
          session: session
        )
      }

      CommandGroup(after: .importExport) {
        Divider()
        Button("Sign Out") {
          if let authStore {
            Task { await authStore.signOut() }
          }
        }
        .disabled(authStore == nil || authStore?.requiresSignIn != true)
        .keyboardShortcut("q", modifiers: [.command, .shift])
      }
    }
  }

  /// Wrapper view to access `@Environment(\.openWindow)` inside commands.
  private struct OpenProfileMenu: View {
    let profileStore: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      Menu("Open Profile") {
        ForEach(profileStore.profiles) { profile in
          Button(profile.label) {
            ProfileWindowLocator.openOrActivate(profile.id, openWindow: openWindow)
          }
        }

        if profileStore.profiles.isEmpty {
          Text("No Profiles")
        }

        Divider()

        SettingsLink {
          Text("Manage Profiles…")
        }
      }
    }
  }
#endif
