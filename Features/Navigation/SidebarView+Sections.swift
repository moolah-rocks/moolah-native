// Section builders, helper methods, and actions for `SidebarView`.

import SwiftUI

extension SidebarView {
  // MARK: - Sections

  func handleAccountEditRequest(_ note: Notification) {
    guard let id = note.object as? UUID,
      let account = accountStore.accounts.by(id: id)
    else { return }
    accountToEdit = account
  }

  #if os(iOS)
    /// Current-bucket section — iOS only. macOS renders Current
    /// Accounts via `SidebarOutlineView` (NSOutlineView), so this
    /// SwiftUI builder is unreferenced on macOS and gated out.
    var currentAccountsSection: some View {
      let groupAware = accountStore.accounts.groupAwareSidebar(
        groups: accountGroupStore.groups,
        excluding: nil,
        alwaysInclude: nil
      )
      return Section {
        ForEach(groupAware.current, id: \.bucketEntryId) { entry in
          bucketEntryView(entry)
        }
        totalRow(label: "Current Total", value: accountStore.convertedCurrentTotal)
      } header: {
        sectionHeader(title: "Current Accounts", addAction: addAccountAction)
      }
    }
  #endif

  var earmarksSection: some View {
    Section {
      ForEach(earmarkStore.visibleEarmarks) { earmark in
        NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
          EarmarkRowView(
            earmark: earmark,
            isSelected: selection == .earmark(earmark.id),
            isEditing: renameBinding(for: earmark.id),
            onRename: renameAction(for: earmark)
          )
        }
        .contextMenu { earmarkContextMenu(for: earmark) }
      }
      .onMove { source, destination in
        Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
      }
      totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
    } header: {
      sectionHeader(title: "Earmarks", addAction: addEarmarkAction)
    }
  }

  #if os(iOS)
    /// Investments-bucket section — iOS only. macOS renders Investments
    /// via `SidebarOutlineView` (NSOutlineView), so this SwiftUI
    /// builder is unreferenced on macOS and gated out.
    var investmentsSection: some View {
      let groupAware = accountStore.accounts.groupAwareSidebar(
        groups: accountGroupStore.groups,
        excluding: nil,
        alwaysInclude: nil
      )
      return Section("Investments") {
        ForEach(groupAware.investments, id: \.bucketEntryId) { entry in
          bucketEntryView(entry)
        }
        totalRow(label: "Investment Total", value: accountStore.convertedInvestmentTotal)
      }
    }

    /// Renders a single bucket entry — standalone account or group with
    /// its members. The switch lives in this helper rather than inline
    /// so each `Section`'s `ForEach` body stays within SwiftLint's
    /// `closure_body_length` budget. iOS-only since both call sites
    /// (`currentAccountsSection` and `investmentsSection`) are
    /// iOS-only.
    @ViewBuilder
    func bucketEntryView(_ entry: SidebarBucketEntry) -> some View {
      switch entry {
      case .account(let account):
        standaloneAccountRowLink(account)
      case let .group(group, members):
        groupSidebarEntry(group, members: members)
      }
    }
  #endif

  @ViewBuilder var totalsSection: some View {
    Section {
      if let currentTotal = accountStore.convertedCurrentTotal,
        let earmarkedTotal = earmarkStore.convertedTotalBalance,
        earmarkedTotal.isPositive
      {
        LabeledContent("Available Funds") {
          InstrumentAmountView(amount: currentTotal - earmarkedTotal)
        }
        .font(.headline)
        .accessibilityLabel("Available Funds: \((currentTotal - earmarkedTotal).formatted)")
      }
      if let netWorth = accountStore.convertedNetWorth {
        LabeledContent("Net Worth") {
          InstrumentAmountView(amount: netWorth)
        }
        .font(.headline)
        .bold()
        .accessibilityLabel("Net Worth: \(netWorth.formatted)")
      }
    }
  }

  @ViewBuilder var navigationSection: some View {
    Section {
      NavigationLink(value: SidebarSelection.analysis) {
        Label("Analysis", systemImage: "chart.bar.xaxis")
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("analysis"))
      NavigationLink(value: SidebarSelection.reports) {
        Label("Reports", systemImage: "chart.bar.fill")
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("reports"))
      NavigationLink(value: SidebarSelection.categories) {
        Label("Categories", systemImage: "tag")
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("categories"))
      NavigationLink(value: SidebarSelection.upcomingTransactions) {
        Label("Upcoming", systemImage: "calendar")
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("upcoming"))
      NavigationLink(value: SidebarSelection.recentlyAdded) {
        recentlyAddedLabel
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("recentlyAdded"))
      NavigationLink(value: SidebarSelection.allTransactions) {
        Label("All Transactions", systemImage: "list.bullet")
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("allTransactions"))
      #if os(iOS)
        navigationToggles
      #endif
    }
  }

  #if os(iOS)
    /// iOS-only visibility toggles shown at the bottom of the navigation
    /// section. Extracted from `navigationSection` to keep its closure
    /// within SwiftLint's `closure_body_length` budget.
    @ViewBuilder var navigationToggles: some View {
      Toggle(isOn: $showHidden) {
        Label(
          showHidden ? "Hide Hidden Accounts" : "Show Hidden Accounts",
          systemImage: showHidden ? "eye" : "eye.slash"
        )
      }
      Toggle(isOn: $showSpam) {
        Label(
          showSpam ? "Hide Spam Transactions" : "Show Spam Transactions",
          systemImage: showSpam ? "eye" : "eye.slash"
        )
      }
    }
  #endif

  // MARK: - Helpers

  /// Dropped CSV onto a sidebar account row: force the import onto that
  /// account, bypassing profile matching. A profile is created on success.
  func ingestDroppedURLs(_ urls: [URL], forcedAccountId: UUID) async {
    for url in urls
    where url.pathExtension.lowercased() == "csv"
      || url.pathExtension.isEmpty
    {
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      guard let data = try? Data(contentsOf: url) else { continue }
      _ = await importStore.ingest(
        data: data,
        source: .droppedFile(url: url, forcedAccountId: forcedAccountId))
    }
  }

  // MARK: - Actions

  func addAccountAction() { showCreateAccountSheet = true }
  func addEarmarkAction() { showCreateEarmarkSheet = true }
}
