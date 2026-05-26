// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  // Internal (not private) so the `+AccountDetail` and `+GroupDetail`
  // extension files can reach the environment stores across the file
  // split.
  @Environment(AuthStore.self) private var authStore
  @Environment(ProfileSession.self) var session
  @Environment(AccountStore.self) var accountStore
  @Environment(TransactionStore.self) var transactionStore
  @Environment(CategoryStore.self) var categoryStore
  @Environment(EarmarkStore.self) var earmarkStore
  @Environment(AccountGroupStore.self) var accountGroupStore
  @Environment(AnalysisStore.self) private var analysisStore
  @Environment(InvestmentStore.self) var investmentStore
  @Environment(ReportingStore.self) private var reportingStore

  #if os(macOS)
    @State private var selection: SidebarSelection? = .analysis
  #else
    @State private var selection: SidebarSelection?
  #endif

  @Environment(\.pendingNavigation) private var pendingNavigationBinding
  @Environment(\.scenePhase) private var scenePhase
  @Environment(ImportStore.self) private var importStore
  @State private var showCreateEarmarkSheet = false
  @State private var showImportCSVPicker = false
  @State private var importError: String?

  // Browser-style back/forward history for the sidebar selection.
  // Helpers live in the history extension below.
  @State private var backStack: [SidebarSelection] = []
  @State private var forwardStack: [SidebarSelection] = []
  // Token set just before goBack/goForward mutates `selection`. Compared
  // against the new value inside `recordHistory(previous:new:)` to skip
  // recording history-driven navigations. Using a value token rather than
  // a Bool flag avoids any dependence on whether SwiftUI delivers
  // `onChange` synchronously or on the next render cycle.
  @State private var historyDrivenSelection: SidebarSelection?

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection)
        .navigationSplitViewColumnWidth(min: 200, ideal: 280)
        .task { await loadSidebarData() }
        .onChange(of: scenePhase) { _, newPhase in
          if newPhase == .active { onScenePhaseActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCSVFile)) { note in
          guard let url = note.object as? URL else { return }
          Task { await ingestCSVFileURL(url) }
        }
        .toolbar {
          #if os(iOS)
            ToolbarItem(placement: .automatic) {
              if case .signedIn = authStore.state {
                UserMenuView()
                  .environment(authStore)
              }
            }
          #endif
        }
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .environment(\.spamInstruments, session.cryptoTokenStore?.spamInstruments ?? [])
    .safeAreaInset(edge: .top, spacing: 0) {
      SyncStatusBanner()
    }
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .focusedSceneValue(\.importCSVAction) {
      showImportCSVPicker = true
    }
    .focusedSceneValue(\.pasteCSVAction) {
      Task { await pasteCSVFromClipboard() }
    }
    .focusedSceneValue(\.refreshAction) {
      Task {
        // AccountStore, EarmarkStore, and CategoryStore are all
        // reactive (subscribe via observeAll() in init); the
        // user-driven refresh only needs to nudge the remaining
        // non-reactive surfaces.
        await importStore.refreshBadge()
      }
    }
    // Pass `nil` to disable the menu item when there is nothing to navigate
    // to — the same pattern used by every other focused-value command above
    // (e.g. `newTransactionAction == nil` disables File > New Transaction…).
    .focusedSceneValue(\.goBackAction, backStack.isEmpty ? nil : { goBack() })
    .focusedSceneValue(\.goForwardAction, forwardStack.isEmpty ? nil : { goForward() })
    .onChange(of: selection) { oldValue, newValue in
      recordHistory(previous: oldValue, new: newValue)
    }
    .sheet(isPresented: $showCreateEarmarkSheet) {
      CreateEarmarkSheet(
        instrument: session.profile.instrument,
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
    .onChange(of: pendingNavigationBinding?.wrappedValue) { _, newValue in
      if let navigation = newValue {
        applyNavigation(navigation.destination)
        pendingNavigationBinding?.wrappedValue = nil
      }
    }
    .fileImporter(
      isPresented: $showImportCSVPicker,
      allowedContentTypes: [.commaSeparatedText, .plainText],
      allowsMultipleSelection: true
    ) { result in
      Task {
        await handleImportPickerResult(result)
      }
    }
    .alert(
      "Import failed",
      isPresented: Binding(
        get: { importError != nil },
        set: { if !$0 { importError = nil } })
    ) {
      Button("OK") { importError = nil }
    } message: {
      Text(importError ?? "")
    }
  }

  private func loadSidebarData() async {
    // AccountStore, EarmarkStore, and CategoryStore are reactive —
    // they load themselves from `init` via `observeAll()`. Only the
    // still-imperative stores are kicked here.
    async let badgeRefresh: Void = importStore.refreshBadge()
    // Start the folder watch (macOS FSEvents or, on iOS, the
    // catch-up scan) if the user has picked one. The call is a
    // no-op when no folder is configured.
    async let folderWatch: Void = session.startFolderWatch()
    // CryptoTokenStore is lazy: registrations stay empty until a Settings
    // view kicks `loadRegistrations()`. The spam-row indicator reads
    // `\.spamInstruments` from the environment at every visible row, so
    // boot the load here to populate the set before the user navigates
    // to a wallet — otherwise the indicator stays hidden until they happen
    // to open Settings → Crypto.
    async let cryptoRegistrations: Void = session.cryptoTokenStore?.loadRegistrations() ?? ()
    _ = await (badgeRefresh, folderWatch, cryptoRegistrations)
  }

  private func onScenePhaseActive() {
    Task {
      await importStore.refreshBadge()
      // iOS doesn't have FSEvents, so foreground-entry is the
      // natural place to re-scan the watched folder. macOS's
      // live watch handles this automatically, but re-scanning
      // on activate is cheap and covers the window-reopened case.
      await session.scanWatchedFolder()
    }
  }

  @ViewBuilder private var detail: some View {
    NavigationStack {
      detailLeaf
    }
    .id(selection)
  }

  @ViewBuilder private var detailLeaf: some View {
    switch selection {
    case .account(let id):
      accountDetail(id: id)
    case .earmark(let id):
      if let earmark = earmarkStore.earmarks.by(id: id) {
        EarmarkDetailView(
          earmark: earmark,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          analysisRepository: analysisStore.repository)
      }
    case .group(let id):
      // Composite detail view bound to an `AccountViewContext`.
      groupDetail(id: id)
    case .recentlyAdded:
      RecentlyAddedView(backend: session.backend)
    case .allTransactions:
      AllTransactionsView(
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
    case .upcomingTransactions:
      UpcomingView(
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
    case .categories:
      CategoriesView(categoryStore: categoryStore)
    case .reports:
      ReportsView(
        reportingStore: reportingStore,
        categories: categoryStore.categories,
        accounts: accountStore.accounts,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
    case .analysis:
      AnalysisView(store: analysisStore)
    case nil:
      ContentUnavailableView(
        "Select an Account", systemImage: "sidebar.left",
        description: Text("Choose an account from the sidebar to view transactions."))
    }
  }

  private func pasteCSVFromClipboard() async {
    #if os(macOS)
      guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
        importError = "Nothing to paste."
        return
      }
    #else
      guard let text = UIPasteboard.general.string, !text.isEmpty else {
        importError = "Nothing to paste."
        return
      }
    #endif
    let data = Data(text.utf8)
    _ = await importStore.ingest(
      data: data,
      source: .paste(text: text, label: "Pasted CSV"))
    selection = .recentlyAdded
  }

  /// Ingest a CSV file URL received from "Open With Moolah" / Dock drop.
  /// Security-scoped resource access follows the same pattern as the
  /// file importer: `url` comes from the system and needs explicit
  /// scope start/stop.
  private func ingestCSVFileURL(_ url: URL) async {
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try Data(contentsOf: url)
      _ = await importStore.ingest(
        data: data,
        source: .droppedFile(url: url, forcedAccountId: nil))
      selection = .recentlyAdded
    } catch {
      importError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
    }
  }

  private func handleImportPickerResult(_ result: Result<[URL], Error>) async {
    switch result {
    case .success(let urls):
      for url in urls {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
          if didStart { url.stopAccessingSecurityScopedResource() }
        }
        do {
          let data = try Data(contentsOf: url)
          _ = await importStore.ingest(
            data: data,
            source: .pickedFile(url: url, securityScoped: didStart))
        } catch {
          importError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
      }
      selection = .recentlyAdded
    case .failure(let error):
      importError = error.localizedDescription
    }
  }

  private func applyNavigation(_ destination: NavigationDestination) {
    if let sidebarSelection = destination.sidebarSelection {
      selection = sidebarSelection
    }
    if case .analysis(let history, let forecast) = destination {
      if let history { analysisStore.historyMonths = history }
      if let forecast { analysisStore.forecastMonths = forecast }
    }
  }
}

// MARK: - Navigation History

extension ContentView {
  private static let historyLimit = 50

  private func recordHistory(previous: SidebarSelection?, new: SidebarSelection?) {
    if let token = historyDrivenSelection, token == new {
      historyDrivenSelection = nil
      return
    }
    guard let previous else { return }
    backStack.append(previous)
    Self.trimToHistoryLimit(&backStack)
    forwardStack.removeAll()
  }

  private func goBack() {
    guard let previous = backStack.popLast() else { return }
    if let current = selection {
      forwardStack.append(current)
      Self.trimToHistoryLimit(&forwardStack)
    }
    historyDrivenSelection = previous
    selection = previous
  }

  private func goForward() {
    guard let next = forwardStack.popLast() else { return }
    if let current = selection {
      backStack.append(current)
      Self.trimToHistoryLimit(&backStack)
    }
    historyDrivenSelection = next
    selection = next
  }

  private static func trimToHistoryLimit(_ stack: inout [SidebarSelection]) {
    if stack.count > historyLimit {
      stack.removeFirst(stack.count - historyLimit)
    }
  }
}

// `accountDetail(id:)` lives in `ContentView+AccountDetail.swift`.
// `groupDetail(id:)` lives in `ContentView+GroupDetail.swift`.
