#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers

  // macOS HSplitView/TabView layout for `SettingsView`. Every member is view
  // composition over the main struct's shared state.
  extension SettingsView {
    /// Current on-device model eligibility. Re-read on `.task` so a device
    /// that finishes downloading Apple Intelligence while Settings is open
    /// will show the Insights tab on next appear without relaunch.
    @MainActor var modelAvailability: ModelAvailability {
      SystemLanguageModelAvailability().current()
    }

    // MARK: - macOS: HSplitView / TabView layout

    /// The Settings scene lives outside `SessionRootView`, so the session
    /// stores aren't in its environment. Resolve one here for the tabs
    /// that depend on per-profile state. Prefer the active profile; fall
    /// back to any open session so Settings still renders after a profile
    /// switch.
    var sessionForSettings: ProfileSession? {
      if let id = profileStore.activeProfileID, let session = sessionManager.sessions[id] {
        return session
      }
      return sessionManager.sessions.values.first
    }

    /// Crypto settings must track the *active* profile's session, not any
    /// open session, so switching to a different profile correctly hides
    /// its token list even when another session is still open.
    /// Returned in full (rather than narrowed to just the
    /// `CryptoTokenStore`) so the tab can also inject the session into
    /// the SwiftUI environment for the embedded `AddTokenSheet`'s picker
    /// to consume — `InstrumentPickerSheet`'s callback variant resolves
    /// its search service / resolver / registry from the session.
    var activeCryptoSession: ProfileSession? {
      guard let id = profileStore.activeProfileID,
        let session = sessionManager.sessions[id],
        session.cryptoTokenStore != nil
      else { return nil }
      return session
    }

    var macOSLayout: some View {
      TabView {
        Tab("Profiles", systemImage: "person.2") {
          profilesContent
        }
        if let session = activeCryptoSession,
          let store = session.cryptoTokenStore
        {
          // SwiftUI's `Tab` does not propagate `.accessibilityIdentifier`
          // to the generated toolbar button on macOS, so the title doubles
          // as the driver lookup label. Both sites reference
          // `UITestIdentifiers.Settings.cryptoTabTitle` so there is one
          // source of truth.
          Tab(UITestIdentifiers.Settings.cryptoTabTitle, systemImage: "bitcoinsign.circle") {
            // Wrap in a NavigationStack so the Discovered Tokens inbox
            // and Spam Tokens views can be pushed via NavigationLink.
            NavigationStack {
              CryptoSettingsView(
                store: store,
                cryptoSyncStore: session.cryptoSyncStore,
                tokenDiscovery: session.cryptoTokenDiscovery
              )
              // The embedded `AddTokenSheet` opens an `InstrumentPickerSheet`
              // whose callback variant pulls its search service, registry,
              // and resolution client from `@Environment(ProfileSession.self)`.
              // Without this injection the picker silently falls back to
              // the static fiat list and crypto search returns no results.
              .environment(session)
            }
          }
        }
        if modelAvailability.isUsable {
          Tab("Insights", systemImage: "sparkles") {
            insightsTabContent
          }
        }
        // macOS Settings tabs host the Form / List directly — the window
        // already supplies chrome and a title, so wrapping in a second
        // `NavigationStack` would produce a duplicate navigation bar.
        Tab("Import", systemImage: "tray.and.arrow.down") {
          importTabContent
        }
        Tab("Rules", systemImage: "list.bullet.rectangle") {
          rulesTabContent
        }
      }
      .frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 560)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
          .frame(minWidth: 400, minHeight: 300)
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
    }

    var profilesContent: some View {
      Group {
        if profileStore.profiles.isEmpty {
          emptyState
        } else {
          HSplitView {
            profileList
              .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            detailPane
              .frame(minWidth: 300, idealWidth: 400)
          }
          .onAppear {
            if selectedProfileID == nil {
              selectedProfileID =
                profileStore.activeProfileID ?? profileStore.profiles.first?.id
            }
          }
        }
      }
    }

    var emptyState: some View {
      ContentUnavailableView {
        Label("No Profiles", systemImage: "person.crop.circle.badge.plus")
      } description: {
        Text("Add a profile to connect to a Moolah server.")
      } actions: {
        Button("Add Profile") {
          showAddProfile = true
        }
        .buttonStyle(.bordered)
      }
    }

    var insightsTabContent: some View {
      Form {
        InsightsSettingsSection()
      }
      .formStyle(.grouped)
      .navigationTitle("Insights")
    }

    @ViewBuilder var importTabContent: some View {
      if let session = sessionForSettings {
        ImportSettingsView()
          .environment(session)
      } else {
        noActiveProfilePlaceholder
      }
    }

    @ViewBuilder var rulesTabContent: some View {
      if let session = sessionForSettings {
        ImportRulesSettingsView()
          .environment(session)
          .environment(session.importRuleStore)
          .environment(session.categoryStore)
      } else {
        noActiveProfilePlaceholder
      }
    }

    var noActiveProfilePlaceholder: some View {
      ContentUnavailableView(
        "No Profile",
        systemImage: "person.crop.circle",
        description: Text("Add a profile to configure this tab.")
      )
    }

    // MARK: - macOS Profile List (sidebar)

    var profileList: some View {
      VStack(spacing: 0) {
        profileListContent
        Divider()
        profileListToolbar
      }
    }

    private var profileListContent: some View {
      List(selection: $selectedProfileID) {
        Section("Profiles") {
          ForEach(profileStore.profiles) { profile in
            profileRow(profile)
              .tag(profile.id)
          }
        }
      }
      .listStyle(.sidebar)
    }

    private var profileListToolbar: some View {
      HStack(spacing: 8) {
        addProfileButton
        removeProfileButton
        importProfileButton
        Spacer()
      }
      .padding(8)
    }

    private var addProfileButton: some View {
      Button {
        showAddProfile = true
      } label: {
        Image(systemName: "plus")
          .frame(minWidth: 24, minHeight: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Add profile")
    }

    private var removeProfileButton: some View {
      Button {
        if let id = selectedProfileID,
          let profile = profileStore.profiles.first(where: { $0.id == id })
        {
          profileToDelete = profile
          showDeleteAlert = true
        }
      } label: {
        Image(systemName: "minus")
          .frame(minWidth: 24, minHeight: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .disabled(selectedProfileID == nil)
      .accessibilityLabel("Remove selected profile")
    }

    private var importProfileButton: some View {
      Button {
        showImportPicker = true
      } label: {
        Image(systemName: "square.and.arrow.down")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Import profile")
    }

    // MARK: - macOS Detail Pane

    @ViewBuilder var detailPane: some View {
      if let selectedID = selectedProfileID,
        let profile = profileStore.profiles.first(where: { $0.id == selectedID })
      {
        profileDetailView(for: profile)
          .id(selectedID)
      } else {
        // Without `maxHeight: .infinity` the `HSplitView` collapses both
        // columns to the intrinsic height of `ContentUnavailableView`, so
        // the sidebar fill stops short of the window's bottom edge.
        ContentUnavailableView(
          "No Profile Selected",
          systemImage: "person.crop.circle",
          description: Text("Select a profile to view its settings.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
#endif
