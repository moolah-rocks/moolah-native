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

  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Environment(AccountStore.self) var accountStore
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Environment(EarmarkStore.self) var earmarkStore
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @Environment(AccountGroupStore.self) var accountGroupStore
  // Sidebar expand / collapse state for `AccountGroup` rows. Persisted
  // per profile in the local-only `account_group_ui` GRDB table —
  // never synced via CloudKit. Internal access for the
  // `SidebarView+Groups.swift` extension.
  @Environment(GroupUIStateStore.self) var groupUIStateStore
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
  // Identifies the sidebar row currently in inline rename mode, if
  // any. Local-only — never persisted, never synced. At most one row
  // is in edit mode at a time across the entire sidebar (accounts,
  // earmarks, future groups).
  // Internal access required by `SidebarView+Sections.swift` extension;
  // cannot be `private` across file boundaries.
  @State var editingRowId: UUID?
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
    #if os(macOS)
      macSidebarBody
    #else
      iosSidebarBody
    #endif
  }

  #if os(macOS)
    /// macOS body: the new `SidebarOutlineView` (NSOutlineView-backed)
    /// renders Current Accounts + Investments at the top, and the
    /// SwiftUI `List` below it carries Earmarks, Totals, and the
    /// navigation rows. Selection rides through a shared
    /// `Binding<SidebarSelection?>` so clicks in either surface update
    /// the same source of truth.
    ///
    /// The two panes scroll **independently** — the VStack does not
    /// share a single scroll container between them. That matches
    /// macOS Finder's source-list-plus-fixed-list layout (where the
    /// "Favorites" outline and the "iCloud / Locations / Tags" list
    /// each manage their own clipping). Future Phase work may revisit
    /// this if user feedback prefers a unified scroll.
    ///
    /// Phase 1 deliberately omits the iOS-only modifiers:
    /// - `.onKeyPress(.return)` for inline rename — not wired on macOS
    ///   until Phase 3 ships AppKit-cell inline editing.
    /// - `.environment(\.editMode, $editMode)` — iOS list reorder mode
    ///   only.
    var macSidebarBody: some View {
      VStack(spacing: 0) {
        SidebarOutlineView(selection: $selection)
        List(selection: $selection) {
          earmarksSection
          totalsSection
          navigationSection
        }
        .listStyle(.sidebar)
      }
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
    #if os(iOS)
      // Inline rename and the Group ▸ submenu are iOS-only until
      // Phase 3 ships AppKit-cell editing and Phase 2 wires
      // drag-and-drop / group membership on the macOS outline. macOS
      // users currently reach grouping via drag-and-drop on the
      // SwiftUI surface (not yet on the outline) and account renaming
      // via the "Edit Account…" item below.
      Button("Rename", systemImage: "character.cursor.ibeam") {
        editingRowId = account.id
      }
      .accessibilityIdentifier(UITestIdentifiers.Sidebar.renameContextMenuItem)
      accountGroupSubmenu(for: account)
    #endif
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

  /// Returns the `onRename` closure for an account-group row. Same
  /// intent-shape as the account / earmark variants; dispatches
  /// `AccountGroupStore.rename`.
  func renameAction(for group: AccountGroup) -> (String) -> Void {
    { newName in
      Task { _ = try? await accountGroupStore.rename(id: group.id, to: newName) }
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
