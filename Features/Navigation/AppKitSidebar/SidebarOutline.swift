#if os(macOS)
  import SwiftUI

  /// SwiftUI bridge to `SidebarOutlineController`. Owned by the macOS
  /// body of `SidebarView`. Rebuilds the `SidebarRowTree.Snapshot` and
  /// the `SidebarCellBuilder` on every SwiftUI update; both are passed
  /// into the controller so it can apply the new state to its
  /// `NSOutlineView` and reconcile expand / selection.
  ///
  /// Selection round-trip: the controller's `selectionChanged` callback
  /// writes back into the parent's `Binding<SidebarSelection?>` via
  /// `SidebarRow.asSelection`. Expansion round-trip: the controller's
  /// `expansionChanged` callback writes back into
  /// `GroupUIStateStore.setExpanded(_:for:)` for `.group` rows only.
  /// Rename round-trip: the controller's `beginRenameRequested` callback
  /// flips `editingRowId` to the currently selected row's id, which
  /// drives the inline `TextField` swap in the hosted SwiftUI row.
  struct SidebarOutline: NSViewControllerRepresentable {
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let earmarkStore: EarmarkStore
    let importStore: ImportStore
    let groupUIStateStore: GroupUIStateStore
    @Binding var selection: SidebarSelection?
    @Binding var accountToEdit: Account?
    @Binding var editingRowId: UUID?
    let onRenameAccount: (Account) -> (String) -> Void
    let onRenameEarmark: (Earmark) -> (String) -> Void
    let onRenameGroup: (AccountGroup) -> (String) -> Void
    let onAddAccount: () -> Void
    let onAddEarmark: () -> Void
    let showHidden: Bool

    func makeNSViewController(context: Context) -> SidebarOutlineController {
      let controller = SidebarOutlineController()
      controller.delegate.selectionChanged = { row in
        selection = row?.asSelection
      }
      controller.delegate.expansionChanged = { row, isExpanded in
        guard case .group(let groupId) = row else { return }
        Task { await groupUIStateStore.setExpanded(isExpanded, for: groupId) }
      }
      controller.delegate.beginRenameRequested = { [weak controller] in
        guard let controller else { return }
        let view = controller.outlineView
        guard view.selectedRow >= 0,
          let row = view.item(atRow: view.selectedRow) as? SidebarRow
        else { return }
        switch row {
        case .account(let id), .earmark(let id), .group(let id):
          editingRowId = id
        case .section, .total, .navigation:
          return
        }
      }
      return controller
    }

    func updateNSViewController(
      _ controller: SidebarOutlineController, context: Context
    ) {
      let tree = SidebarRowTree.build(from: makeSnapshot())
      controller.delegate.cellBuilder = makeCellBuilder()
      controller.apply(
        tree: tree,
        expandedGroupIds: groupUIStateStore.expandedGroupIds,
        selection: selection)
    }

    private func makeSnapshot() -> SidebarRowTree.Snapshot {
      SidebarRowTree.Snapshot(
        accounts: accountStore.accounts,
        groups: accountGroupStore.groups,
        earmarks: earmarkStore.visibleEarmarks,
        currentTotal: accountStore.convertedCurrentTotal,
        investmentTotal: accountStore.convertedInvestmentTotal,
        earmarkedTotal: earmarkStore.convertedTotalBalance,
        netWorth: accountStore.convertedNetWorth,
        showHidden: showHidden,
        unreviewedBadgeCount: importStore.unreviewedBadgeCount)
    }

    private func makeCellBuilder() -> SidebarCellBuilder {
      SidebarCellBuilder(
        accountStore: accountStore,
        accountGroupStore: accountGroupStore,
        earmarkStore: earmarkStore,
        importStore: importStore,
        availableFunds: {
          guard let current = accountStore.convertedCurrentTotal,
            let earmarked = earmarkStore.convertedTotalBalance
          else { return nil }
          return current - earmarked
        },
        selectionBinding: $selection,
        accountToEditBinding: $accountToEdit,
        editingRowIdBinding: $editingRowId,
        onRenameAccount: onRenameAccount,
        onRenameEarmark: onRenameEarmark,
        onRenameGroup: onRenameGroup,
        onAddAccount: onAddAccount,
        onAddEarmark: onAddEarmark)
    }
  }
#endif
