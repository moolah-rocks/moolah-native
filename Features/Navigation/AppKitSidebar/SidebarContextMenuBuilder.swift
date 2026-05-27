#if os(macOS)
  import AppKit
  import SwiftUI

  /// Builds the AppKit `NSMenu` attached to a sidebar account row's
  /// right-click menu. Mirrors the menu previously built inline by
  /// `SidebarOutlineView.makeAccountContextMenu(for:)` so identifiers
  /// and action shape are preserved across the rewrite — UI tests find
  /// the menu by `UITestIdentifiers.Sidebar.editAccountContextMenuItem`
  /// and the "Edit Account…" action opens the standard edit sheet.
  ///
  /// Using an AppKit `NSMenu` (rather than a SwiftUI `.contextMenu` on
  /// the hosted row) keeps the menu open across re-renders of the
  /// hosted SwiftUI tree: AppKit's menu-tracking session owns the menu
  /// independent of any view replacement.
  enum SidebarContextMenuBuilder {
    @MainActor
    static func accountMenu(
      accountId: UUID,
      accountStore: AccountStore,
      selection: Binding<SidebarSelection?>,
      accountToEdit: Binding<Account?>
    ) -> NSMenu {
      let actions = CellMenuActions(
        onEdit: {
          // Look up the latest account by ID at click time. Capturing
          // a snapshot would freeze "Edit Account…" against pre-edit
          // data after a save.
          guard let fresh = accountStore.accounts.by(id: accountId) else { return }
          accountToEdit.wrappedValue = fresh
        },
        onViewTransactions: { selection.wrappedValue = .account(accountId) })

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

      // `NSMenuItem.target` is unowned; without a separate owner the
      // actions object would be deallocated before the user clicks.
      // Associating it with the menu keeps it alive for the menu's
      // lifetime, which matches the cell's lifetime (`cell.menu = menu`).
      objc_setAssociatedObject(menu, &cellActionsKey, actions, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }
  }

  nonisolated(unsafe) private var cellActionsKey: UInt8 = 0

  /// Target/action sink for the per-cell AppKit context menu. Each
  /// menu gets its own instance capturing closures bound to a single
  /// account; the instance is kept alive for the menu's lifetime via
  /// `objc_setAssociatedObject` on the `NSMenu`.
  @MainActor
  private final class CellMenuActions: NSObject {
    private let onEdit: () -> Void
    private let onViewTransactions: () -> Void

    init(onEdit: @escaping () -> Void, onViewTransactions: @escaping () -> Void) {
      self.onEdit = onEdit
      self.onViewTransactions = onViewTransactions
    }

    @objc
    func editAction(_ sender: Any?) { onEdit() }

    @objc
    func viewTransactionsAction(_ sender: Any?) { onViewTransactions() }
  }
#endif
