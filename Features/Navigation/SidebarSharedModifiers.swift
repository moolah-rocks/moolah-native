// Cross-platform modifier stack shared between the macOS and iOS
// sidebar bodies. Lives in its own file so neither `SidebarView.swift`
// nor `SidebarView+Sections.swift` carries the full modifier chain
// twice. The modifier is `fileprivate` to the sidebar feature — it is
// not intended for use elsewhere.

import SwiftUI

/// Cross-platform modifier stack for `SidebarView`. Wraps the chain
/// once so the macOS and iOS bodies don't each carry a copy. State and
/// store handles are passed in explicitly because some of
/// `SidebarView`'s properties are `private` and cannot be reached from
/// a sibling type by inspecting the view value.
struct SidebarSharedModifiers: ViewModifier {
  let session: ProfileSession
  let accountStore: AccountStore
  let earmarkStore: EarmarkStore
  let transactionStore: TransactionStore
  @Binding var showHidden: Bool
  @Binding var showSpam: Bool
  @Binding var selection: SidebarSelection?
  let selectedAccountBinding: Binding<Account?>
  @Binding var showCreateEarmarkSheet: Bool
  @Binding var showCreateAccountSheet: Bool
  @Binding var accountToEdit: Account?
  let onRequestAccountEdit: (Notification) -> Void

  func body(content: Content) -> some View {
    content
      .navigationTitle("")
      .modifier(sceneValues)
      .modifier(storeBridges)
      .refreshable {
        // Both AccountStore and EarmarkStore are reactive (subscribe via
        // observeAll() in init), so pull-to-refresh has nothing
        // imperative left to nudge here. Pull is still wired so the
        // system gesture resolves with the standard animation.
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SyncProgressFooter()
      }
      #if os(macOS)
        .toolbar { toolbarContent }
      #endif
      .modifier(sheets)
      .onReceive(
        NotificationCenter.default.publisher(for: .requestAccountEdit),
        perform: onRequestAccountEdit
      )
      .onReceive(
        NotificationCenter.default.publisher(for: .requestAccountSync)
      ) { handleSyncRequest($0, fullResync: false) }
      .onReceive(
        NotificationCenter.default.publisher(for: .requestAccountResync)
      ) { handleSyncRequest($0, fullResync: true) }
  }

  /// Shared sink for both `.requestAccountSync` and
  /// `.requestAccountResync` — the menu-bar Account menu (and any other
  /// surface, such as a sidebar context menu) posts one of these two
  /// notifications with the target account's `UUID` as `object`.
  /// Resolves the account the same way `handleAccountEditRequest`
  /// resolves `accountToEdit`, then dispatches to
  /// `SyncedAccountStore.syncAccount`. Silently ignores unknown ids and
  /// non-synced accounts (e.g. a stale notification for an account
  /// deleted or retyped since it was posted).
  private func handleSyncRequest(_ note: Notification, fullResync: Bool) {
    guard let id = note.object as? UUID,
      let account = accountStore.accounts.by(id: id),
      account.type.isSynced,
      let syncStore = session.cryptoSyncStore
    else { return }
    Task { await syncStore.syncAccount(account, fullResync: fullResync) }
  }

  /// Focused-scene-value bindings: surfaced as keypath-bound focus
  /// values so menu-bar commands (`MoolahDomainCommands`) can pick up
  /// the current sidebar context.
  private var sceneValues: some ViewModifier {
    SidebarSceneValuesModifier(
      showHidden: $showHidden,
      showSpam: $showSpam,
      selection: $selection,
      selectedAccountBinding: selectedAccountBinding,
      showCreateEarmarkSheet: $showCreateEarmarkSheet,
      showCreateAccountSheet: $showCreateAccountSheet)
  }

  /// Store-bridging modifiers: propagate `@AppStorage` flags into the
  /// account / earmark / transaction stores on first appearance and on
  /// change.
  private var storeBridges: some ViewModifier {
    SidebarStoreBridgesModifier(
      accountStore: accountStore,
      earmarkStore: earmarkStore,
      transactionStore: transactionStore,
      showHidden: showHidden,
      showSpam: showSpam)
  }

  /// The three sheets driven by sidebar state: create earmark, create
  /// account, edit account.
  private var sheets: some ViewModifier {
    SidebarSheetsModifier(
      session: session,
      accountStore: accountStore,
      earmarkStore: earmarkStore,
      showCreateEarmarkSheet: $showCreateEarmarkSheet,
      showCreateAccountSheet: $showCreateAccountSheet,
      accountToEdit: $accountToEdit)
  }

  #if os(macOS)
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
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
}

/// Carries the focused-scene-value bindings out of the main shared
/// modifier so the latter stays inside SwiftLint's body-length budget.
private struct SidebarSceneValuesModifier: ViewModifier {
  @Binding var showHidden: Bool
  @Binding var showSpam: Bool
  @Binding var selection: SidebarSelection?
  let selectedAccountBinding: Binding<Account?>
  @Binding var showCreateEarmarkSheet: Bool
  @Binding var showCreateAccountSheet: Bool

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.showHiddenAccounts, $showHidden)
      .focusedSceneValue(\.showSpamTransactions, $showSpam)
      .focusedSceneValue(\.sidebarSelection, $selection)
      .focusedSceneValue(\.selectedAccount, selectedAccountBinding)
      .focusedSceneValue(\.newEarmarkAction) {
        showCreateEarmarkSheet = true
      }
      .focusedSceneValue(\.newAccountAction) {
        showCreateAccountSheet = true
      }
  }
}

/// Bridges the `@AppStorage` hidden / spam flags through to the
/// account, earmark, and transaction stores on appearance and on
/// change.
private struct SidebarStoreBridgesModifier: ViewModifier {
  let accountStore: AccountStore
  let earmarkStore: EarmarkStore
  let transactionStore: TransactionStore
  let showHidden: Bool
  let showSpam: Bool

  func body(content: Content) -> some View {
    content
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
  }
}

/// The three sidebar-owned sheets: create earmark, create account,
/// edit account.
private struct SidebarSheetsModifier: ViewModifier {
  let session: ProfileSession
  let accountStore: AccountStore
  let earmarkStore: EarmarkStore
  @Binding var showCreateEarmarkSheet: Bool
  @Binding var showCreateAccountSheet: Bool
  @Binding var accountToEdit: Account?

  func body(content: Content) -> some View {
    content
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
  }
}
