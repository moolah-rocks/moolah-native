#if os(iOS)
  import SwiftUI
  import UniformTypeIdentifiers

  // iOS NavigationStack layout for `SettingsView`. Every member is view
  // composition over the main struct's shared state.
  extension SettingsView {

    // MARK: - iOS: NavigationStack layout

    /// Current on-device model eligibility. Cheap synchronous read; re-checked
    /// on each view update so a `.modelNotReady → .available` flip is observed
    /// without relaunch.
    @MainActor var modelAvailability: ModelAvailability {
      SystemLanguageModelAvailability().current()
    }

    var iOSLayout: some View {
      List {
        profilesSection
        addImportProfileSection
        cryptoSection
        if modelAvailability.isUsable {
          InsightsSettingsSection()
        }
        importSettingsSection
        helpSection
      }
      .navigationTitle("Settings")
      .overlay {
        if isImporting || isExporting {
          ProgressView(isImporting ? "Importing\u{2026}" : "Exporting\u{2026}")
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
      }
      .sheet(isPresented: $showExportSheet) {
        if let exportFileURL {
          ShareSheetView(url: exportFileURL)
        }
      }
      .alert(deleteAlertTitle, isPresented: $showDeleteAlert) {
        deleteAlertButtons
      } message: {
        deleteAlertMessage
      }
      .fileImporter(
        isPresented: $showImportPicker,
        allowedContentTypes: [.json]
      ) { result in
        Task { await handleImport(result: result) }
      }
      .alert(
        "Import Failed",
        isPresented: .init(
          get: { importError != nil },
          set: { if !$0 { importError = nil } }
        )
      ) {
        Button("OK") { importError = nil }
      } message: {
        if let importError {
          Text(importError)
        }
      }
      .alert(
        "Export Failed",
        isPresented: .init(
          get: { exportError != nil },
          set: { if !$0 { exportError = nil } }
        )
      ) {
        Button("OK") { exportError = nil }
      } message: {
        if let exportError {
          Text(exportError)
        }
      }
    }

    var profilesSection: some View {
      Section("Profiles") {
        ForEach(profileStore.profiles) { profile in
          NavigationLink {
            profileDetailView(for: profile)
              .navigationTitle(profile.label)
          } label: {
            profileRow(profile)
          }
          .swipeActions(edge: .leading) {
            if profile.id == profileStore.activeProfileID {
              Button {
                Task { await handleExport(profile: profile) }
              } label: {
                Label("Export", systemImage: "square.and.arrow.up")
              }
              .tint(.blue)
            }
          }
        }
        .onDelete { indexSet in
          if let index = indexSet.first {
            profileToDelete = profileStore.profiles[index]
            showDeleteAlert = true
          }
        }
      }
    }

    var addImportProfileSection: some View {
      Section {
        Button {
          showAddProfile = true
        } label: {
          Label("Add Profile", systemImage: "plus")
        }
        Button {
          showImportPicker = true
        } label: {
          Label("Import Profile", systemImage: "square.and.arrow.down")
        }
      }
    }

    @ViewBuilder var cryptoSection: some View {
      if let session = activeSession,
        let store = session.cryptoTokenStore
      {
        Section {
          NavigationLink {
            CryptoSettingsView(
              store: store,
              cryptoSyncStore: session.cryptoSyncStore,
              tokenDiscovery: session.cryptoTokenDiscovery
            )
            // The embedded `AddTokenSheet` opens an `InstrumentPickerSheet`
            // whose callback variant pulls its search service, registry,
            // and resolution client from `@Environment(ProfileSession.self)`.
            // Without this injection the picker silently falls back to the
            // static fiat list and crypto search returns no results.
            .environment(session)
          } label: {
            Label("Crypto Tokens", systemImage: "bitcoinsign.circle")
          }
        }
      }
    }

    var importSettingsSection: some View {
      Section("Import") {
        NavigationLink {
          ImportSettingsView()
        } label: {
          Label("CSV Import", systemImage: "tray.and.arrow.down")
        }
        NavigationLink {
          ImportRulesSettingsView()
        } label: {
          Label("Import Rules", systemImage: "list.bullet.rectangle")
        }
      }
    }

    var helpSection: some View {
      Section("Help") {
        if let url = URL(string: "https://moolah.rocks/help") {
          Link(destination: url) {
            Label("Moolah Help", systemImage: "questionmark.circle")
          }
        }
      }
    }
  }

  /// Wraps UIActivityViewController for presenting a share sheet with a file URL.
  struct ShareSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(
      _ uiViewController: UIActivityViewController, context: Context
    ) {}
  }
#endif
