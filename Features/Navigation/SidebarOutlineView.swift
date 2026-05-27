#if os(macOS)
  import AppKit
  import SwiftUI

  /// macOS-only outline view rendering one bucket of the sidebar
  /// (Current Accounts **or** Investments — never both). Wraps
  /// `NSOutlineView` via the vendored `OutlineView` package
  /// (`Vendored/OutlineView/`). Section chrome ("Current Accounts" /
  /// "Investments") is supplied by the surrounding SwiftUI `Section`
  /// in `SidebarView+Sections.swift`; this view renders only the
  /// bucket's accounts and groups as a flat root with members nested
  /// under their group.
  ///
  /// Selection rides through a shared `Binding<SidebarSelection?>`
  /// with the host `List(selection:)` (earmarks / totals / nav) —
  /// clicking in either surface updates the same binding.
  ///
  /// Phase 1 scope: render items, support row selection, and persist
  /// per-group expand state through `GroupUIStateStore` (see
  /// `expansionBinding(groupStore:)`). **No drag-and-drop** (Phase 2).
  /// **No inline rename** (Phase 3) — rename remains via the
  /// "Edit Account…" context menu item which opens the full edit
  /// sheet.
  struct SidebarOutlineView: View {
    @Environment(AccountStore.self) private var accountStore
    @Environment(AccountGroupStore.self) private var accountGroupStore
    @Environment(GroupUIStateStore.self) private var groupUIStateStore
    @Binding var selection: SidebarSelection?
    /// Which bucket this outline instance renders. The parent
    /// `SidebarView` instantiates one `SidebarOutlineView` per bucket
    /// so the two bucket headers can be flat SwiftUI sections with
    /// Earmarks interleaved between them — the previous
    /// single-outline layout couldn't express that ordering.
    let bucket: AccountBucket
    // moolah: account-edit binding owned by the parent `SidebarView`.
    // Right-clicking a row in the NSOutlineView invokes "Edit Account…"
    // which assigns to this binding; `SidebarSharedModifiers` then
    // presents the edit sheet. Threading the binding (rather than
    // hosting state inside `SidebarOutlineView`) keeps a single source
    // of truth across the outline + SwiftUI-list halves of the
    // sidebar so the SwiftUI sheet driver remains the parent.
    @Binding var accountToEdit: Account?

    var body: some View {
      let items = SidebarOutlineItem.tree(
        accounts: accountStore.accounts,
        groups: accountGroupStore.groups,
        bucket: bucket)
      OutlineView(
        items,
        children: \.children,
        selection: outlineSelectionBinding,
        content: cellView(for:)
      )
      // Deliberately NOT `.outlineViewStyle(.sourceList)` — the source-list
      // style paints its own grey background that doubles up against the
      // host SwiftUI Section's `.listStyle(.sidebar)` chrome. The plain
      // (`.automatic`) style with cleared background lets the SwiftUI
      // sidebar material show through cleanly.
      .outlineViewExpandedItems(Self.expansionBinding(groupStore: groupUIStateStore))
      // `NSViewControllerRepresentable` does not surface an
      // intrinsic content size to SwiftUI's `List` layout — without
      // a frame the row collapses to zero height. Compute the
      // height from the visible row count: each root item is one
      // row; an expanded group contributes its members on top.
      .frame(height: computedHeight(for: items))
    }

    /// Height contributed by this outline inside its host `List`
    /// row. Each visible row uses `Self.rowHeight`; expanded groups
    /// add their member rows. Collapsed groups contribute only their
    /// own row.
    private func computedHeight(for items: [SidebarOutlineItem]) -> CGFloat {
      let expanded = groupUIStateStore.expandedGroupIds
      var visibleRows = 0
      for item in items {
        visibleRows += 1
        if case .group(let id) = item.kind,
          expanded.contains(id),
          let children = item.children
        {
          visibleRows += children.count
        }
      }
      return CGFloat(visibleRows) * Self.rowHeight
    }

    /// Per-row height used by both the height computation above and
    /// (implicitly) `NSOutlineView`'s automatic row sizing. Matches
    /// SwiftUI `List(.sidebar)` row chrome (icon + label + balance with
    /// 4pt vertical padding either side via
    /// `NSTableCellView.hosting`); picking the same number here keeps
    /// the bound `.frame(height:)` in sync with the actual cells the
    /// outline lays out, so the parent `List` row doesn't crop or pad.
    private static let rowHeight: CGFloat = 28

    // MARK: - Cell rendering

    @MainActor
    private func cellView(for item: SidebarOutlineItem) -> NSView {
      switch item.kind {
      case .account(let id): return accountCell(id: id)
      case .group(let id): return groupCell(id: id)
      }
    }

    private func accountCell(id: UUID) -> NSView {
      guard let account = accountStore.accounts.by(id: id) else {
        // Defensive: an account row exists in the outline tree but its
        // record disappeared from the store between tree-build and
        // cell-build (e.g. mid-deletion). An empty cell renders blank
        // for one frame; the next data update drops the row entirely.
        assertionFailure("SidebarOutlineView: account \(id) missing from store")
        return NSTableCellView()
      }
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.account(id),
        menu: makeAccountContextMenu(for: account)
      ) {
        AccountSidebarRow(account: account, isSelected: selection == .account(id))
          .environment(accountStore)
      }
    }

    // moolah: macOS outline-cell context menu, materialised as a real
    // AppKit `NSMenu` rather than a SwiftUI `.contextMenu`. Phase 1
    // initially used `.contextMenu` on the hosted SwiftUI row, but the
    // hosted tree gets rebuilt by `OutlineViewController.updateData`
    // whenever the data source changes (e.g.
    // `AccountStore.convertedBalances` emitting between the right-click
    // and the NSMenu materialising): the menu's host view is replaced
    // under AppKit's foot and the menu dismisses or never opens. An
    // AppKit `NSMenu` attached to `NSTableCellView.menu` is owned by
    // AppKit's menu-tracking session, independent of any SwiftUI
    // re-render, so the menu stays open across data refreshes.
    //
    // Mirrors the `accountContextMenu(for:)` builder in `SidebarView`
    // but pared down to the items that work in Phase 1 (no inline
    // rename, no group submenu — both are iOS-only until later
    // phases). "Edit Account…" is the regression-critical item: UI
    // tests right-click a sidebar account row and expect to find the
    // menu by its accessibility identifier (see
    // `EditAccountValuationPickerTests`).
    @MainActor
    private func makeAccountContextMenu(for account: Account) -> NSMenu {
      let accountId = account.id
      // Capture the bindings (not `self`) so the closures keep working
      // even though the surrounding `SidebarOutlineView` struct value
      // is rebuilt on every SwiftUI body re-render. The bindings stay
      // pointed at the parent `SidebarView`'s source of truth.
      //
      // Capture the `AccountStore` and look up the latest account by
      // ID at click time. `NSOutlineView`'s update path only rebuilds
      // cells on identity changes (insert / remove), so a cell — and
      // therefore its menu — persists across in-place account edits.
      // Capturing the `Account` value would freeze the menu's "Edit
      // Account…" action against the stale snapshot it was built with,
      // re-opening the edit dialog with pre-edit data after a save.
      let accountToEdit = $accountToEdit
      let selection = $selection
      let accountStore = accountStore
      let actions = CellMenuActions(
        onEdit: {
          guard let fresh = accountStore.accounts.by(id: accountId) else { return }
          accountToEdit.wrappedValue = fresh
        },
        onViewTransactions: { selection.wrappedValue = .account(accountId) }
      )
      let menu = NSMenu()
      let editItem = NSMenuItem(
        title: "Edit Account\u{2026}",
        action: #selector(CellMenuActions.editAction(_:)),
        keyEquivalent: "")
      editItem.target = actions
      editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
      editItem.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
      menu.addItem(editItem)
      let viewItem = NSMenuItem(
        title: "View Transactions",
        action: #selector(CellMenuActions.viewTransactionsAction(_:)),
        keyEquivalent: "")
      viewItem.target = actions
      viewItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
      menu.addItem(viewItem)
      // moolah: NSMenuItem's `target` is `weak`/unowned by default, so the
      // `CellMenuActions` instance has no owner once this function returns.
      // Attach it to the menu's lifetime via an associated object — the
      // association is retained as long as the menu lives, and the menu
      // lives as long as the cell holds it (`cell.menu = menu`).
      objc_setAssociatedObject(
        menu, &Self.cellActionsKey, actions, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }

    nonisolated(unsafe) private static var cellActionsKey: UInt8 = 0

    private func groupCell(id: UUID) -> NSView {
      guard let group = accountGroupStore.by(id: id) else {
        // Defensive: same rationale as `accountCell`.
        assertionFailure("SidebarOutlineView: group \(id) missing from store")
        return NSTableCellView()
      }
      let memberIds = accountStore.accounts.ordered
        .filter { $0.groupId == id }
        .sorted { $0.position < $1.position }
        .map(\.id)
      let isSelected = selection == .group(id)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.group(id)
      ) {
        GroupAggregateBalanceLoader(
          memberIds: memberIds,
          targetInstrument: group.instrument
        ) { balance in
          AccountGroupSidebarRow(
            group: group,
            isSelected: isSelected,
            // `NSOutlineView` draws the disclosure triangle for us; the
            // row's own chevron is suppressed via `showChevron: false`.
            // The expand state itself rides through
            // `.outlineViewExpandedItems` → `expansionBinding` →
            // `GroupUIStateStore`, so the `isExpanded` binding on the
            // SwiftUI row is unused in the outline path. A constant
            // `false` keeps the row API happy without giving it write
            // authority — it would race the persisted store.
            isExpanded: .constant(false),
            aggregateBalance: balance,
            showChevron: false
          )
        }
        .environment(accountStore)
      }
    }

    // MARK: - Expansion mapping

    /// Builds the two-way binding between
    /// `Set<SidebarOutlineItem.Kind>` (which the vendored `OutlineView`
    /// uses to drive per-row expand state) and
    /// `GroupUIStateStore.expandedGroupIds`.
    ///
    /// Only `.group(id)` kinds are tracked — account rows are leaves
    /// and never appear in the bound set. Section headers no longer
    /// exist in the tree (they're SwiftUI sections now), so there's
    /// nothing to anchor open.
    ///
    /// Each group transition is dispatched as a `Task` calling
    /// `setExpanded(_:for:)`. `GroupUIStateStore` is `@MainActor`-bound;
    /// the inherited MainActor context keeps the persistence write off
    /// the binding's synchronous setter path. The observation stream
    /// re-emits the authoritative `expandedGroupIds`, which re-renders
    /// the outline against the new set — the store stays the source of
    /// truth, the binding is purely a translation layer.
    ///
    /// `setExpanded(_:for:)` is `async` (not `async throws`) and catches
    /// its own repository errors into `GroupUIStateStore.error`; the
    /// fire-and-forget `Task` is safe here — no error-swallowing rule is
    /// violated because the callee, not the callsite, owns recovery.
    /// `@MainActor`-bound because the returned `Binding`'s `get` reads
    /// `groupStore.expandedGroupIds` synchronously and the setter
    /// dispatches into `groupStore.setExpanded(_:for:)`. Both touch
    /// `@MainActor`-isolated store state, so the surrounding context
    /// must already be on the main actor when the binding is built.
    @MainActor
    static func expansionBinding(
      groupStore: GroupUIStateStore
    ) -> Binding<Set<SidebarOutlineItem.Kind>> {
      Binding(
        get: { Set(groupStore.expandedGroupIds.map { .group($0) }) },
        set: { newValue in
          let newGroupExpansion: Set<UUID> = Set(
            newValue.compactMap { kind -> UUID? in
              if case .group(let id) = kind { return id }
              return nil
            })
          let old = groupStore.expandedGroupIds
          for groupId in newGroupExpansion.subtracting(old) {
            Task { await groupStore.setExpanded(true, for: groupId) }
          }
          for groupId in old.subtracting(newGroupExpansion) {
            Task { await groupStore.setExpanded(false, for: groupId) }
          }
        }
      )
    }

    // MARK: - Selection mapping

    /// Maps between the outline's `SidebarOutlineItem?` selection and
    /// the app's `SidebarSelection?`. Earmark / navigation selections
    /// that come from the sibling SwiftUI `List` map to `nil` on the
    /// outline side so the outline does not highlight a stale row.
    private var outlineSelectionBinding: Binding<SidebarOutlineItem?> {
      Binding(
        get: {
          switch selection {
          case .account(let id):
            return SidebarOutlineItem(kind: .account(id), children: nil)
          case .group(let id):
            return SidebarOutlineItem(kind: .group(id), children: [])
          case .none, .earmark, .recentlyAdded, .allTransactions,
            .upcomingTransactions, .categories, .reports, .analysis:
            return nil
          }
        },
        set: { newItem in
          switch newItem?.kind {
          case .account(let id): selection = .account(id)
          case .group(let id): selection = .group(id)
          case .none: break
          }
        }
      )
    }
  }

  /// Target/action sink for the per-cell AppKit context menu.
  ///
  /// `NSMenuItem.action` is a selector dispatched against
  /// `NSMenuItem.target`, so we can't pass a SwiftUI closure directly.
  /// Each cell gets its own `CellMenuActions` capturing closures bound
  /// to that cell's account; the actions instance is kept alive for the
  /// menu's lifetime via `objc_setAssociatedObject` on the `NSMenu`
  /// (see `SidebarOutlineView.makeAccountContextMenu(for:)`).
  ///
  /// `@MainActor` because the captured closures mutate
  /// `SidebarOutlineView`'s SwiftUI bindings (`accountToEdit`,
  /// `selection`), which are read/written on the main actor.
  @MainActor
  private final class CellMenuActions: NSObject {
    private let onEdit: () -> Void
    private let onViewTransactions: () -> Void

    init(
      onEdit: @escaping () -> Void,
      onViewTransactions: @escaping () -> Void
    ) {
      self.onEdit = onEdit
      self.onViewTransactions = onViewTransactions
    }

    @objc
    func editAction(_ sender: Any?) {
      onEdit()
    }

    @objc
    func viewTransactionsAction(_ sender: Any?) {
      onViewTransactions()
    }
  }
#endif
