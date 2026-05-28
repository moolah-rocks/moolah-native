import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case earmark(UUID)
  /// Selection of an `AccountGroup` row. Phase 5 wires the detail view
  /// that consumes this case; for Phase 4, selecting a group simply
  /// updates the binding and the detail leaf falls through to a
  /// placeholder. Carries the group's UUID so a later detail view can
  /// resolve the group from `AccountGroupStore`.
  case group(UUID)
  case recentlyAdded
  case allTransactions
  case upcomingTransactions
  case categories
  case reports
  case analysis
}

struct SidebarView: View {
  // MARK: - Properties
  // Properties below are `internal` (not `private`) so the iOS section
  // builders in `SidebarView+Sections.swift` can reach them across
  // file boundaries.

  @Environment(AccountStore.self) var accountStore
  @Environment(EarmarkStore.self) var earmarkStore
  @Environment(AccountGroupStore.self) var accountGroupStore
  /// Sidebar expand / collapse state for `AccountGroup` rows. Persisted
  /// per profile in the local-only `account_group_ui` GRDB table —
  /// never synced via CloudKit.
  @Environment(GroupUIStateStore.self) var groupUIStateStore
  @Environment(ProfileSession.self) private var session
  @Environment(ImportStore.self) var importStore
  @Environment(TransactionStore.self) private var transactionStore
  @Binding var selection: SidebarSelection?
  @State var showCreateEarmarkSheet = false
  @State var showCreateAccountSheet = false
  @State var accountToEdit: Account?
  /// Identifies the sidebar row currently in inline rename mode, if
  /// any. Local-only — never persisted, never synced. At most one row
  /// is in edit mode at a time across the entire sidebar (accounts,
  /// earmarks, future groups).
  @State var editingRowId: UUID?
  @AppStorage("showHiddenAccounts") var showHidden = false
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
    #if os(macOS)
      macSidebarBody
    #else
      iosSidebarBody
    #endif
  }

  #if os(macOS)
    /// macOS body: a single full-bleed `NSOutlineView` rendering every
    /// sidebar row — accounts, groups, earmarks, totals, navigation —
    /// via the `SidebarOutline` representable. Cross-platform toolbar /
    /// sheets / sync footer are still carried by `sharedBodyModifiers`.
    var macSidebarBody: some View {
      SidebarOutline(
        accountStore: accountStore,
        accountGroupStore: accountGroupStore,
        earmarkStore: earmarkStore,
        importStore: importStore,
        groupUIStateStore: groupUIStateStore,
        selection: $selection,
        accountToEdit: $accountToEdit,
        editingRowId: $editingRowId,
        onRenameAccount: renameAction(for:),
        onRenameEarmark: renameAction(for:),
        onRenameGroup: renameAction(for:),
        onAddAccount: { showCreateAccountSheet = true },
        onAddEarmark: { showCreateEarmarkSheet = true },
        showHidden: showHidden
      )
      .modifier(sharedBodyModifiers)
    }
  #endif

  #if os(iOS)
    /// iOS body: preserves the existing single-`List` layout with all
    /// five sections (Current Accounts, Earmarks, Investments, Totals,
    /// Navigation). Phase 1 leaves this path completely unchanged.
    var iosSidebarBody: some View {
      List(selection: $selection) {
        currentAccountsSection
        earmarksSection
        investmentsSection
        totalsSection
        navigationSection
      }
      .listStyle(.sidebar)
      .onKeyPress(.return, action: handleReturnKey)
      .environment(\.editMode, $editMode)
      .modifier(sharedBodyModifiers)
    }

    /// `.onKeyPress(.return)` handler for the iOS body. Only responds
    /// when the selection points at a row that supports inline rename —
    /// other selections (analysis / reports / etc.) pass through
    /// unhandled so any default Return behaviour is preserved.
    private func handleReturnKey() -> KeyPress.Result {
      switch selection {
      case .account(let id):
        guard accountStore.accounts.by(id: id) != nil else { return .ignored }
        editingRowId = id
        return .handled
      case .earmark(let id):
        guard earmarkStore.earmarks.by(id: id) != nil else { return .ignored }
        editingRowId = id
        return .handled
      case .group(let id):
        guard accountGroupStore.by(id: id) != nil else { return .ignored }
        editingRowId = id
        return .handled
      case .none, .recentlyAdded, .allTransactions, .upcomingTransactions,
        .categories, .reports, .analysis:
        return .ignored
      }
    }
  #endif

  /// Bundles the cross-platform modifier stack: navigation title,
  /// focused-scene values, store-driven `onChange` / `onAppear` hooks,
  /// the macOS toolbar, the sync-progress footer, and the three sheets
  /// (create earmark / create account / edit account). Built as a
  /// concrete value here so both the macOS and iOS bodies pick it up
  /// via `.modifier(...)` without duplicating the chain. The modifier
  /// itself lives in `SidebarSharedModifiers.swift`.
  ///
  /// Platform-only modifiers (`.onKeyPress`, `.environment(editMode)`)
  /// live on the platform-specific bodies above so they don't leak.
  private var sharedBodyModifiers: SidebarSharedModifiers {
    SidebarSharedModifiers(
      session: session,
      accountStore: accountStore,
      earmarkStore: earmarkStore,
      transactionStore: transactionStore,
      showHidden: $showHidden,
      showSpam: $showSpam,
      selection: $selection,
      selectedAccountBinding: selectedAccountBinding,
      showCreateEarmarkSheet: $showCreateEarmarkSheet,
      showCreateAccountSheet: $showCreateAccountSheet,
      accountToEdit: $accountToEdit,
      onRequestAccountEdit: handleAccountEditRequest
    )
  }

}

#if os(iOS)
  // The helpers below are only used by the iOS section builders. macOS
  // renders the sidebar through `SidebarOutline` (`AppKitSidebar/`),
  // whose cells produce equivalent SwiftUI / AppKit content directly.
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
      accountGroupSubmenu(for: account)
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
        Button(action: addAction) {
          Image(systemName: "plus").font(.caption)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title.lowercased())")
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
#endif

extension SidebarView {
  // MARK: - Inline Rename State Coordination (iOS + macOS)

  /// Returns a binding that reports `true` when this row id is the one
  /// currently being inline-renamed, and (on `set(true)`) makes it so.
  /// Centralises the one-at-a-time invariant.
  func renameBinding(for id: UUID) -> Binding<Bool> {
    Self.renameBinding(for: id, editingId: $editingRowId)
  }

  /// Extracted as a static so the one-at-a-time invariant can be
  /// unit-tested (see `SidebarRenameBindingTests`) without constructing
  /// a view. The instance wrapper `renameBinding(for:)` delegates here;
  /// `SidebarCellBuilder` calls the static directly with its own
  /// `editingRowId` binding.
  static func renameBinding(
    for id: UUID, editingId: Binding<UUID?>
  ) -> Binding<Bool> {
    Binding(
      get: { editingId.wrappedValue == id },
      set: { newValue in editingId.wrappedValue = newValue ? id : nil }
    )
  }

  /// Returns the `onRename` closure for an account row — single source
  /// of truth for the inline-rename dispatch shape, used by both the
  /// Current and Investments sections on iOS and by the AppKit outline
  /// cells on macOS.
  func renameAction(for account: Account) -> (String) -> Void {
    { newName in
      Task { _ = try? await accountStore.rename(id: account.id, to: newName) }
    }
  }

  /// Returns the `onRename` closure for an earmark row. Mirrors the
  /// account variant but without `try?` — `EarmarkStore.rename` is
  /// non-throwing (errors surface on `earmarkStore.error` internally).
  func renameAction(for earmark: Earmark) -> (String) -> Void {
    { newName in
      Task { _ = await earmarkStore.rename(id: earmark.id, to: newName) }
    }
  }

  /// Returns the `onRename` closure for an account-group row. Same
  /// dispatch shape as the account / earmark variants; errors surface
  /// on `accountGroupStore.error` before the rethrow is discarded here.
  func renameAction(for group: AccountGroup) -> (String) -> Void {
    { newName in
      Task { _ = try? await accountGroupStore.rename(id: group.id, to: newName) }
    }
  }
}
