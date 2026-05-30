#if os(macOS)
  import OSLog
  import SwiftUI
  import UniformTypeIdentifiers

  /// Export/Import buttons for use inside a CommandGroup.
  struct ExportImportButtons: View {
    let profileStore: ProfileStore
    let containerManager: ProfileContainerManager
    let syncCoordinator: SyncCoordinator
    let session: ProfileSession?

    @Environment(\.openWindow) private var openWindow

    private let logger = Logger(subsystem: "com.moolah.app", category: "Export")

    var body: some View {
      Button("Export Profile\u{2026}") {
        guard let session else { return }
        logger.info("Export: starting for profile \(session.profile.label, privacy: .public)")
        Task { await exportProfile(session: session) }
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(session == nil)

      Button("Import Profile\u{2026}") {
        Task { await importProfile() }
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
    }

    @MainActor
    private func exportProfile(session: ProfileSession) async {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "\(session.profile.label).json"
      panel.canCreateDirectories = true

      guard await present(panel) == .OK, let url = panel.url else { return }

      logger.info("Export: saving to \(url.path, privacy: .public)")
      session.activeExport = ActiveExport(
        profileLabel: session.profile.label,
        stageLabel: ActiveExport.stageLabel(for: "starting"))
      defer { session.activeExport = nil }

      let coordinator = ExportCoordinator()
      do {
        try await coordinator.exportToFile(
          url: url,
          backend: session.backend,
          profile: session.profile,
          progress: { step in
            session.activeExport?.stageLabel = ActiveExport.stageLabel(for: step)
          }
        )
        logger.info("Export: complete — saved to \(url.path, privacy: .public)")
      } catch {
        logger.error("Export: failed — \(error)")
        await present(NSAlert(error: error))
      }
    }

    @MainActor
    private func importProfile() async {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.json]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false

      guard await present(panel) == .OK, let url = panel.url else { return }

      do {
        let coordinator = ExportCoordinator()
        let newProfileId = try await coordinator.importNewProfileFromFile(
          url: url,
          profileStore: profileStore,
          containerManager: containerManager,
          syncCoordinator: syncCoordinator
        )
        ProfileWindowLocator.openOrActivate(newProfileId, openWindow: openWindow)
      } catch {
        await present(NSAlert(error: error))
      }
    }

    /// Presents `panel` as a sheet on the current key/main window, or as a
    /// free-floating modal when no window is open (e.g. the user invoked the
    /// menu item with every profile window closed). `beginSheetModal(for:)`
    /// silently no-ops without a parent window, so the fallback is required
    /// for the menu items to function in that state.
    @MainActor
    private func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        return await panel.beginSheetModal(for: window)
      }
      return panel.runModal()
    }

    @MainActor
    private func present(_ alert: NSAlert) async {
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        _ = await alert.beginSheetModal(for: window)
      } else {
        alert.runModal()
      }
    }
  }
#endif
