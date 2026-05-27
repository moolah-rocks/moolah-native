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
      .outlineViewStyle(.sourceList)
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
    /// (implicitly) `NSOutlineView`'s automatic row sizing. Sourced
    /// from the source-list style's default row metric — picking the
    /// same number here keeps the bound height in sync with the
    /// actual cells the outline lays out.
    private static let rowHeight: CGFloat = 24

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
        accessibilityIdentifier: UITestIdentifiers.Sidebar.account(id)
      ) {
        AccountSidebarRow(account: account, isSelected: selection == .account(id))
          .environment(accountStore)
          .contextMenu { accountContextMenu(for: account) }
      }
    }

    // moolah: macOS outline-cell context menu. Mirrors the
    // `accountContextMenu(for:)` builder in `SidebarView` but pared down
    // to the items that work in Phase 1 (no inline rename, no group
    // submenu — both are iOS-only until later phases). "Edit Account…"
    // is the regression-critical item: UI tests right-click a sidebar
    // account row and expect to find the menu by its accessibility
    // identifier (see `EditAccountValuationPickerTests`).
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
#endif
