// Reason: SwiftUI sidebar layout mixes Section / Label / NavigationLink calls
// whose argument lists span multiple lines for readability; the rule's
// first-arg-on-opening-line convention fights the SwiftUI declarative idiom
// without improving clarity.
// swiftlint:disable multiline_arguments

import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case earmark(UUID)
  case recentlyAdded
  case allTransactions
  case upcomingTransactions
  case categories
  case reports
  case analysis
}

struct SidebarView: View {
  // MARK: - Properties

  @Environment(AccountStore.self) private var accountStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(ProfileSession.self) private var session
  @Environment(ImportStore.self) private var importStore
  @Environment(TransactionStore.self) private var transactionStore
  @Binding var selection: SidebarSelection?
  @State private var showCreateEarmarkSheet = false
  @State private var showCreateAccountSheet = false
  @State private var accountToEdit: Account?
  @AppStorage("showHiddenAccounts") private var showHidden = false
  @AppStorage("showSpamTransactions") private var showSpam = false

  #if os(iOS)
    @State private var editMode: EditMode = .inactive
  #endif

  private var selectedAccountBinding: Binding<Account?> {
    Binding(
      get: {
        guard case .account(let id) = selection else { return nil }
        return accountStore.accounts.by(id: id)
      },
      set: { newAccount in
        selection = newAccount.map { .account($0.id) }
      }
    )
  }

  // MARK: - Body

  var body: some View {
    List(selection: $selection) {
      currentAccountsSection
      earmarksSection
      investmentsSection
      totalsSection
      navigationSection
    }
    .listStyle(.sidebar)
    .navigationTitle("")
    .focusedSceneValue(\.showHiddenAccounts, $showHidden)
    .focusedSceneValue(\.showSpamTransactions, $showSpam)
    .focusedSceneValue(\.sidebarSelection, $selection)
    .focusedSceneValue(\.selectedAccount, selectedAccountBinding)
    .onChange(of: showHidden) { _, newValue in
      accountStore.showHidden = newValue
      earmarkStore.showHidden = newValue
    }
    .onChange(of: showSpam) { _, newValue in
      transactionStore.showSpam = newValue
    }
    .onAppear {
      accountStore.showHidden = showHidden
      earmarkStore.showHidden = showHidden
      transactionStore.showSpam = showSpam
    }
    #if os(iOS)
      .environment(\.editMode, $editMode)
    #endif
    .refreshable {
      // Both AccountStore and EarmarkStore are reactive (subscribe via
      // observeAll() in init), so pull-to-refresh has nothing imperative
      // left to nudge here. Pull is still wired so the system gesture
      // resolves with the standard animation.
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SyncProgressFooter()
    }
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateAccountSheet = true
          } label: {
            Label("New Account", systemImage: "plus")
          }
          .help("Create new account")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newAccountButton)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateEarmarkSheet = true
          } label: {
            Label("New Earmark", systemImage: "bookmark.fill")
          }
          .help("Create new earmark")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newEarmarkButton)
        }
      }
    #endif
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .focusedSceneValue(\.newAccountAction) {
      showCreateAccountSheet = true
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
    .sheet(isPresented: $showCreateAccountSheet) {
      CreateAccountView(
        instrument: session.profile.instrument,
        accountStore: accountStore,
        cryptoSyncStore: session.cryptoSyncStore)
    }
    .sheet(item: $accountToEdit) { account in
      EditAccountView(
        account: account, accountStore: accountStore)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .requestAccountEdit),
      perform: handleAccountEditRequest
    )
  }

}

extension SidebarView {
  // MARK: - Sections

  private func handleAccountEditRequest(_ note: Notification) {
    guard let id = note.object as? UUID,
      let account = accountStore.accounts.by(id: id)
    else { return }
    accountToEdit = account
  }

  private var currentAccountsSection: some View {
    Section {
      ForEach(accountStore.currentAccounts) { account in
        NavigationLink(value: SidebarSelection.account(account.id)) {
          AccountSidebarRow(account: account, isSelected: selection == .account(account.id))
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

  private var earmarksSection: some View {
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

  private var investmentsSection: some View {
    Section("Investments") {
      ForEach(accountStore.investmentAccounts) { account in
        NavigationLink(value: SidebarSelection.account(account.id)) {
          AccountSidebarRow(account: account, isSelected: selection == .account(account.id))
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

  @ViewBuilder private var totalsSection: some View {
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

  @ViewBuilder private var navigationSection: some View {
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
    @ViewBuilder private var navigationToggles: some View {
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

  private func reorderCurrentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.currentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(accounts)
  }

  /// Dropped CSV onto a sidebar account row: force the import onto that
  /// account, bypassing profile matching. A profile is created on success.
  private func ingestDroppedURLs(_ urls: [URL], forcedAccountId: UUID) async {
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

  private func reorderInvestmentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.investmentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(
      accounts, positionOffset: accountStore.currentAccounts.count)
  }

  // MARK: - Actions

  private func addAccountAction() { showCreateAccountSheet = true }
  private func addEarmarkAction() { showCreateEarmarkSheet = true }

  // MARK: - Row Builders

  private var recentlyAddedLabel: some View {
    HStack {
      Label("Recently Added", systemImage: "tray.full")
      Spacer()
      if importStore.unreviewedBadgeCount > 0 {
        Text("\(importStore.unreviewedBadgeCount)")
          .font(.caption)
          .monospacedDigit()
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.tint, in: Capsule())
          .foregroundStyle(.white)
          .accessibilityLabel(
            "\(importStore.unreviewedBadgeCount) recently imported need review")
      }
    }
  }

  private func totalRow(label: String, value: InstrumentAmount?) -> some View {
    LabeledContent(label) {
      if let value {
        InstrumentAmountView(amount: value)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .foregroundStyle(.secondary)
    .font(.callout)
  }

  @ViewBuilder
  private func accountContextMenu(for account: Account) -> some View {
    Button("Edit Account\u{2026}", systemImage: "pencil") {
      accountToEdit = account
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
    Button("View Transactions", systemImage: "list.bullet") {
      selection = .account(account.id)
    }
  }

  @ViewBuilder
  private func sectionHeader(title: String, addAction: @escaping () -> Void) -> some View {
    HStack {
      Text(title)
      Spacer()
      #if os(iOS)
        Button(action: addAction) {
          Image(systemName: "plus").font(.caption)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title.lowercased())")
      #endif
    }
  }
}
