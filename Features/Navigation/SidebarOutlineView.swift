#if os(macOS)
  import AppKit
  import SwiftUI

  /// macOS-only outline-rendered top section of the sidebar: Current
  /// Accounts + Investments. Wraps `NSOutlineView` via the vendored
  /// `OutlineView` package (`Vendored/OutlineView/`). Selection rides
  /// through a shared `Binding<SidebarSelection?>` with the sibling
  /// SwiftUI `List` below (earmarks / totals / nav) — clicking in either
  /// surface updates the same binding.
  ///
  /// Phase 1 scope: render items, support row selection, render section
  /// headers as source-list group rows, and persist per-group expand
  /// state through `GroupUIStateStore` (see
  /// `expansionBinding(groupStore:)`). **No drag-and-drop** (Phase 2).
  /// **No inline rename** (Phase 3) — rename remains via the
  /// "Edit Account…" context menu item which opens the full edit sheet.
  struct SidebarOutlineView: View {
    @Environment(AccountStore.self) private var accountStore
    @Environment(AccountGroupStore.self) private var accountGroupStore
    @Environment(GroupUIStateStore.self) private var groupUIStateStore
    @Binding var selection: SidebarSelection?

    var body: some View {
      OutlineView(
        SidebarOutlineItem.tree(
          accounts: accountStore.accounts,
          groups: accountGroupStore.groups),
        children: \.children,
        selection: outlineSelectionBinding,
        content: cellView(for:)
      )
      .outlineViewStyle(.sourceList)
      .outlineViewIsGroupItem { item in
        switch item.kind {
        case .currentAccountsHeader, .investmentsHeader: return true
        case .account, .group: return false
        }
      }
      .outlineViewExpandedItems(Self.expansionBinding(groupStore: groupUIStateStore))
    }

    // MARK: - Cell rendering

    @MainActor
    private func cellView(for item: SidebarOutlineItem) -> NSView {
      switch item.kind {
      case .currentAccountsHeader: return headerCell("Current Accounts")
      case .investmentsHeader: return headerCell("Investments")
      case .account(let id): return accountCell(id: id)
      case .group(let id): return groupCell(id: id)
      }
    }

    /// Source-list group-row cell. `NSOutlineView` styles the cell with
    /// the capitalised, secondary-text-colour treatment when
    /// `outlineView(_:isGroupItem:)` returns `true` — we just supply the
    /// text. The explicit title keeps VoiceOver pronunciation
    /// predictable (NSOutlineView's automatic uppercasing is a render
    /// transform, not the underlying accessibility string).
    private func headerCell(_ title: String) -> NSView {
      let cell = NSTableCellView()
      let field = NSTextField(labelWithString: title)
      field.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(field)
      cell.textField = field
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }

    private func accountCell(id: UUID) -> NSView {
      guard let account = accountStore.accounts.by(id: id) else {
        return NSTableCellView()
      }
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.account(id)
      ) {
        AccountSidebarRow(account: account)
          .environment(accountStore)
      }
    }

    private func groupCell(id: UUID) -> NSView {
      guard let group = accountGroupStore.by(id: id) else {
        return NSTableCellView()
      }
      let memberIds = accountStore.accounts.ordered
        .filter { $0.groupId == id }
        .sorted { $0.position < $1.position }
        .map(\.id)
      return NSTableCellView.hosting(
        accessibilityIdentifier: UITestIdentifiers.Sidebar.group(id)
      ) {
        GroupAggregateBalanceLoader(
          memberIds: memberIds,
          targetInstrument: group.instrument
        ) { balance in
          AccountGroupSidebarRow(
            group: group,
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
    /// Section-header items (`.currentAccountsHeader` /
    /// `.investmentsHeader`) are unconditionally reported as expanded —
    /// the user can't permanently collapse "Current Accounts" or
    /// "Investments" away. The setter ignores any add / remove of
    /// header kinds; only `.group(id)` transitions reach the store.
    ///
    /// Account-row kinds (`.account(id)`) are leaves with no children,
    /// so they never appear in the bound set. The setter tolerates
    /// them defensively but treats them as no-ops.
    ///
    /// Each group transition is dispatched as a `Task` calling
    /// `setExpanded(_:for:)`. `GroupUIStateStore` is `@MainActor`-bound;
    /// the inherited MainActor context keeps the persistence write off
    /// the binding's synchronous setter path. The observation stream
    /// re-emits the authoritative `expandedGroupIds`, which re-renders
    /// the outline against the new set — the store stays the source of
    /// truth, the binding is purely a translation layer.
    @MainActor
    static func expansionBinding(
      groupStore: GroupUIStateStore
    ) -> Binding<Set<SidebarOutlineItem.Kind>> {
      Binding(
        get: {
          var set: Set<SidebarOutlineItem.Kind> = [
            .currentAccountsHeader,
            .investmentsHeader,
          ]
          for groupId in groupStore.expandedGroupIds {
            set.insert(.group(groupId))
          }
          return set
        },
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
    /// the app's `SidebarSelection?`. Section-header rows are
    /// non-selectable (the `outlineViewIsGroupItem` hook disables
    /// selection on them via the vendored delegate); they never reach
    /// the setter. Earmark / navigation selections that come from the
    /// sibling SwiftUI `List` map to `nil` on the outline side so the
    /// outline does not highlight a stale row.
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
          case .currentAccountsHeader, .investmentsHeader, .none:
            break
          }
        }
      )
    }
  }
#endif
