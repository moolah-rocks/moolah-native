import Foundation
import MoolahMCP
import SwiftUI
import Synchronization

/// All preview actions use disconnected sessions, memory credentials and an isolated directory.
private struct MCPSettingsPreviewHost: View {
  enum Screen { case settings, error, create, edit, credential }

  let screen: Screen
  @State private var controller: MCPServerController?
  @State private var profiles: ProfileStore?
  @State private var credential: MCPCreatedCredential?

  var body: some View {
    Group {
      if let controller, let profiles {
        content(controller: controller, profiles: profiles)
          .environment(controller)
          .environment(profiles)
      } else {
        ProgressView("Preparing preview…")
      }
    }
    .task { await prepare() }
  }

  @ViewBuilder
  private func content(controller: MCPServerController, profiles: ProfileStore) -> some View {
    switch screen {
    case .settings, .error: MCPSettingsView().frame(width: 700, height: 700)
    case .create: MCPIntegrationEditorView(profiles: profiles.profiles)
    case .edit:
      MCPIntegrationEditorView(profiles: profiles.profiles, grant: credential?.grant)
    case .credential:
      if let credential { MCPCredentialView(credential: credential) }
    }
  }

  private func prepare() async {
    guard controller == nil else { return }
    do {
      let containers = try ProfileContainerManager.forTesting()
      let suite = "mcp-preview.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suite) else { return }
      let store = ProfileStore(defaults: defaults)
      store.profiles = [Profile(label: "Household and long-term investments — extended family")]
      let sessions = SessionManager(
        resources: .disconnected,
        containerManager: containers,
        profileIndexRepository: containers.profileIndexRepository
      )
      let preferences = MCPServerPreferences(defaults: defaults)
      preferences.isEnabled = screen == .error
      let secrets = MCPPreviewSecrets(shouldFail: screen == .error)
      let controller = MCPServerController(
        sessions: sessions,
        preferences: preferences,
        persistence: secrets,
        history: MCPAuditHistory(
          url: URL.temporaryDirectory.appending(path: "mcp-preview-\(suite)/audit.json")
        )
      )
      let grants = try await MCPGrantStore.open(
        persistence: screen == .error ? MCPPreviewSecrets() : secrets
      )
      credential = try await grants.create(
        label: "Local financial assistant with a longer integration name",
        profileIDs: Set(store.profiles.map(\.id))
      )
      controller.grants = credential.map { [$0.grant] } ?? []
      if screen == .error {
        controller.errorMessage =
          "Moolah couldn’t start the local listener. Check that the port is free, then turn MCP off and on."
        controller.state = .failed
      }
      self.controller = controller
      profiles = store
    } catch { return }
  }
}

private final class MCPPreviewSecrets: Sendable {
  private let data = Mutex<Data?>(nil)
  private let shouldFail: Bool

  init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
}

extension MCPPreviewSecrets: MCPSecretPersisting {
  func readData() throws -> Data? {
    if shouldFail { throw MCPStorageFailure.unavailable }
    return data.withLock { $0 }
  }
  func writeData(_ value: Data) throws { data.withLock { $0 = value } }
}

#Preview("MCP settings · light") {
  MCPSettingsPreviewHost(screen: .settings).preferredColorScheme(.light)
}
#Preview("MCP settings · dark error") {
  MCPSettingsPreviewHost(screen: .error).preferredColorScheme(.dark)
}
#Preview("Create integration") { MCPSettingsPreviewHost(screen: .create) }
#Preview("Edit integration") { MCPSettingsPreviewHost(screen: .edit) }
#Preview("Credential disclosure") { MCPSettingsPreviewHost(screen: .credential) }
