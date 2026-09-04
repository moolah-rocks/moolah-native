import SwiftUI

/// Recently imported transactions rendered through the standard transaction
/// list. The wrapper owns only import-specific concerns: the setup panel,
/// import-timestamp window, file drop, and sidebar review-badge refresh.
struct RecentlyAddedView: View {
  let backend: any BackendProvider

  @Environment(ImportStore.self) private var importStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @State private var window: RecentlyAddedWindow = .last24Hours
  @State private var filterReferenceDate = Date()
  @State private var importError: String?
  @State private var showImportIssues = false

  var body: some View {
    TransactionListView(
      title: "Recently Added",
      filter: recentFilter,
      accounts: accountStore.accounts,
      categories: categoryStore.categories,
      earmarks: earmarkStore.earmarks,
      transactionStore: transactionStore,
      allowsScheduledFilter: false,
      allowsAddingTransactions: false,
      emptyState: TransactionListEmptyState(
        title: emptyStateTitle,
        systemImage: "tray",
        description: emptyStatePrompt)
    )
    .dropDestination(for: URL.self) { urls, _ in
      guard urls.contains(where: ImportStore.supportsImportFile) else { return false }
      Task {
        let report = await importStore.ingestDroppedFiles(urls)
        importError = report.userMessage
      }
      return true
    }
    .alert(
      "Couldn’t import all files",
      isPresented: Binding(
        get: { importError != nil },
        set: { if !$0 { importError = nil } })
    ) {
      Button("Dismiss") { importError = nil }
    } message: {
      Text(importError ?? "")
    }
    .toolbar { recentlyAddedToolbar }
    .task(id: importStore.recentSessions.count) {
      await importStore.reloadStagingLists()
    }
    .onChange(of: window) {
      filterReferenceDate = Date()
    }
    .task(id: transactionStore.transactionContentGeneration) {
      await importStore.refreshBadge()
    }
    .focusedSceneValue(
      \.showImportIssuesAction,
      importIssueCount > 0 ? { showImportIssues = true } : nil
    )
    .onChange(of: importIssueCount) { _, count in
      if count == 0 {
        showImportIssues = false
      }
    }
  }
}

extension RecentlyAddedView {
  private var importIssueCount: Int {
    importStore.pendingSetup.count + importStore.failedFiles.count
  }

  @ToolbarContentBuilder private var recentlyAddedToolbar: some ToolbarContent {
    if importIssueCount > 0 {
      ToolbarItem(placement: .automatic) {
        Button {
          showImportIssues.toggle()
        } label: {
          Label(
            "Show Import Issues",
            systemImage: "exclamationmark.triangle.fill")
        }
        .accessibilityValue("\(importIssueCount)")
        .accessibilityHint("Shows files that need setup or could not be imported")
        .popover(isPresented: $showImportIssues) { importIssuesPopover }
      }
    }
    ToolbarItem(placement: .automatic) {
      Picker("Time window", selection: $window) {
        ForEach(RecentlyAddedWindow.allCases) { option in
          Text(option.label).tag(option)
        }
      }
      .pickerStyle(.menu)
      .accessibilityLabel("Time window")
    }
  }

  private var importIssuesPopover: some View {
    ScrollView {
      RecentlyAddedNeedsSetupPanel(
        backend: backend, staging: importStore.staging)
    }
    .frame(
      minWidth: 420,
      idealWidth: 500,
      maxWidth: 600,
      idealHeight: 300,
      maxHeight: 500
    )
    .padding()
  }

  private var recentFilter: TransactionFilter {
    TransactionFilter(importedAtRange: window.importedAtRange(now: filterReferenceDate))
  }

  private var emptyStateTitle: String {
    "No imported transactions to show"
  }

  private var emptyStatePrompt: String {
    if window != .all {
      return "Choose All to include transactions outside this time window."
    }
    return "Import a CSV to add transactions here."
  }

}
