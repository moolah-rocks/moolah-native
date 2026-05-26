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

  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Environment(AccountStore.self) var accountStore
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Environment(EarmarkStore.self) var earmarkStore
  @Environment(ProfileSession.self) private var session
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Environment(ImportStore.self) var importStore
  @Environment(TransactionStore.self) private var transactionStore
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Binding var selection: SidebarSelection?
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @State var showCreateEarmarkSheet = false
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @State var showCreateAccountSheet = false
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @State var accountToEdit: Account?
  /// Identifies the sidebar row currently in inline rename mode, if
  /// any. Local-only — never persisted, never synced. At most one row
  /// is in edit mode at a time across the entire sidebar (accounts,
  /// earmarks, future groups).
  @State private var editingRowId: UUID?
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @AppStorage("showHiddenAccounts") var showHidden = false
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @AppStorage("showSpamTransactions") var showSpam = false

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
  // MARK: - View Builders
  // recentlyAddedLabel, totalRow, accountContextMenu, sectionHeader

  var recentlyAddedLabel: some View {
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

  func totalRow(label: String, value: InstrumentAmount?) -> some View {
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
  func accountContextMenu(for account: Account) -> some View {
    Button("Rename", systemImage: "character.cursor.ibeam") {
      editingRowId = account.id
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
    Button("Edit Account\u{2026}", systemImage: "pencil") {
      accountToEdit = account
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
    Button("View Transactions", systemImage: "list.bullet") {
      selection = .account(account.id)
    }
  }

  @ViewBuilder
  func sectionHeader(title: String, addAction: @escaping () -> Void) -> some View {
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

  // MARK: - State Coordination
  // renameBinding, renameAction

  /// Returns a binding that reports `true` when this row id is the one
  /// currently being inline-renamed, and (on `set(true)`) makes it so.
  /// Centralises the one-at-a-time invariant.
  func renameBinding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { editingRowId == id },
      set: { newValue in editingRowId = newValue ? id : nil }
    )
  }

  /// Returns the `onRename` closure for an account row — single source
  /// of truth for the inline-rename dispatch shape, used by both the
  /// Current and Investments sections.
  func renameAction(for account: Account) -> (String) -> Void {
    { newName in
      Task { _ = try? await accountStore.rename(id: account.id, to: newName) }
    }
  }

  /// Returns the `onRename` closure for an earmark row — earmark
  /// counterpart of `renameAction(for: Account)`. Same intent-shape;
  /// dispatches `EarmarkStore.rename`.
  func renameAction(for earmark: Earmark) -> (String) -> Void {
    { newName in
      Task { _ = await earmarkStore.rename(id: earmark.id, to: newName) }
    }
  }

  @ViewBuilder
  func earmarkContextMenu(for earmark: Earmark) -> some View {
    Button("Rename", systemImage: "character.cursor.ibeam") {
      editingRowId = earmark.id
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
  }
}
