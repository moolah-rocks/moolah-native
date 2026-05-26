// Section builders, helper methods, and actions for `SidebarView`.

// Reason: SwiftUI sidebar layout mixes Section / Label / NavigationLink calls
// whose argument lists span multiple lines for readability; the rule's
// first-arg-on-opening-line convention fights the SwiftUI declarative idiom
// without improving clarity.
// swiftlint:disable multiline_arguments

import SwiftUI

extension SidebarView {
  // MARK: - Sections

  func handleAccountEditRequest(_ note: Notification) {
    guard let id = note.object as? UUID,
      let account = accountStore.accounts.by(id: id)
    else { return }
    accountToEdit = account
  }

  var currentAccountsSection: some View {
    Section {
      ForEach(accountStore.currentAccounts) { account in
        NavigationLink(value: SidebarSelection.account(account.id)) {
          AccountSidebarRow(
            account: account,
            isSelected: selection == .account(account.id),
            isEditing: renameBinding(for: account.id),
            onRename: renameAction(for: account)
          )
        }
        .dropDestination(for: URL.self) { urls, _ in
          Task { await ingestDroppedURLs(urls, forcedAccountId: account.id) }
          return !urls.isEmpty
        }
        .accessibilityIdentifier(UITestIdentifiers.Sidebar.account(account.id))
        .contextMenu { accountContextMenu(for: account) }
      }
      .onMove { source, destination in
        Task { await reorderCurrentAccounts(from: source, to: destination) }
      }
      totalRow(label: "Current Total", value: accountStore.convertedCurrentTotal)
    } header: {
      sectionHeader(title: "Current Accounts", addAction: addAccountAction)
    }
  }

  var earmarksSection: some View {
    Section {
      ForEach(earmarkStore.visibleEarmarks) { earmark in
        NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
          SidebarRowView(
            icon: "bookmark.fill", name: earmark.name,
            amount: earmarkStore.convertedBalance(for: earmark.id),
            isSelected: selection == .earmark(earmark.id))
        }
      }
      .onMove { source, destination in
        Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
      }
      totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
    } header: {
      sectionHeader(title: "Earmarks", addAction: addEarmarkAction)
    }
  }

  var investmentsSection: some View {
    Section("Investments") {
      ForEach(accountStore.investmentAccounts) { account in
        NavigationLink(value: SidebarSelection.account(account.id)) {
          AccountSidebarRow(
            account: account,
            isSelected: selection == .account(account.id),
            isEditing: renameBinding(for: account.id),
            onRename: renameAction(for: account)
          )
        }
        .accessibilityIdentifier(UITestIdentifiers.Sidebar.account(account.id))
        .contextMenu { accountContextMenu(for: account) }
      }
      .onMove { source, destination in
        Task { await reorderInvestmentAccounts(from: source, to: destination) }
      }
      totalRow(label: "Investment Total", value: accountStore.convertedInvestmentTotal)
    }
  }

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

  func reorderCurrentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.currentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(accounts)
  }

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

  func reorderInvestmentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.investmentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(
      accounts, positionOffset: accountStore.currentAccounts.count)
  }

  // MARK: - Actions

  func addAccountAction() { showCreateAccountSheet = true }
  func addEarmarkAction() { showCreateEarmarkSheet = true }
}
