#if os(macOS)
  import AppKit
  import SwiftUI

  /// Builds the AppKit `NSMenu` attached to each sidebar row's
  /// right-click menu. UI tests find menu items by accessibility
  /// identifier (e.g. `renameContextMenuItem`, `editAccountContextMenuItem`)
  /// and dispatch fires the associated `on…` closure.
  ///
  /// The account menu also carries a "Resync Now (Full History)" item,
  /// but only when the account is synced (`AccountType.isSynced` —
  /// crypto or exchange). It posts `.requestAccountResync`, the same
  /// notification the menu-bar Account → Resync Now command posts
  /// (`MoolahDomainCommands`), so the shared `SidebarSharedModifiers`
  /// observer resolves the account and dispatches the sync — no new
  /// store plumbing needed here.
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
      accountToEdit: Binding<Account?>,
      onBeginRename: @escaping () -> Void
    ) -> NSMenu {
      let actions = AccountMenuActions(
        onRename: onBeginRename,
        onEdit: {
          guard let fresh = accountStore.accounts.by(id: accountId) else { return }
          accountToEdit.wrappedValue = fresh
        },
        onViewTransactions: { selection.wrappedValue = .account(accountId) },
        onResync: {
          NotificationCenter.default.post(name: .requestAccountResync, object: accountId)
        })

      let menu = NSMenu()

      let renameItem = NSMenuItem(
        title: "Rename",
        action: #selector(AccountMenuActions.renameAction(_:)),
        keyEquivalent: "")
      renameItem.target = actions
      renameItem.image = NSImage(
        systemSymbolName: "character.cursor.ibeam",
        accessibilityDescription: nil)
      renameItem.setAccessibilityIdentifier(
        UITestIdentifiers.Sidebar.renameContextMenuItem)
      menu.addItem(renameItem)

      let editItem = NSMenuItem(
        title: "Edit Account\u{2026}",
        action: #selector(AccountMenuActions.editAction(_:)),
        keyEquivalent: "")
      editItem.target = actions
      editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
      editItem.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.editAccountContextMenuItem)
      menu.addItem(editItem)

      let viewItem = NSMenuItem(
        title: "View Transactions",
        action: #selector(AccountMenuActions.viewTransactionsAction(_:)),
        keyEquivalent: "")
      viewItem.target = actions
      viewItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
      viewItem.setAccessibilityIdentifier(
        UITestIdentifiers.Sidebar.viewTransactionsContextMenuItem)
      menu.addItem(viewItem)

      if accountStore.accounts.by(id: accountId)?.type.isSynced == true {
        menu.addItem(.separator())
        menu.addItem(resyncMenuItem(target: actions))
      }

      objc_setAssociatedObject(
        menu, &AssociationKeys.cellActions, actions, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }

    @MainActor
    static func earmarkMenu(
      earmarkId: UUID,
      onBeginRename: @escaping () -> Void
    ) -> NSMenu {
      let actions = RenameOnlyMenuActions(onRename: onBeginRename)
      let menu = NSMenu()
      let renameItem = NSMenuItem(
        title: "Rename",
        action: #selector(RenameOnlyMenuActions.renameAction(_:)),
        keyEquivalent: "")
      renameItem.target = actions
      renameItem.image = NSImage(
        systemSymbolName: "character.cursor.ibeam",
        accessibilityDescription: nil)
      renameItem.setAccessibilityIdentifier(
        UITestIdentifiers.Sidebar.renameContextMenuItem)
      menu.addItem(renameItem)
      objc_setAssociatedObject(
        menu, &AssociationKeys.cellActions, actions, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }

    @MainActor
    static func groupMenu(
      groupId: UUID,
      onBeginRename: @escaping () -> Void
    ) -> NSMenu {
      let actions = RenameOnlyMenuActions(onRename: onBeginRename)
      let menu = NSMenu()
      let renameItem = NSMenuItem(
        title: "Rename",
        action: #selector(RenameOnlyMenuActions.renameAction(_:)),
        keyEquivalent: "")
      renameItem.target = actions
      renameItem.image = NSImage(
        systemSymbolName: "character.cursor.ibeam",
        accessibilityDescription: nil)
      renameItem.setAccessibilityIdentifier(
        UITestIdentifiers.Sidebar.renameContextMenuItem)
      menu.addItem(renameItem)
      objc_setAssociatedObject(
        menu, &AssociationKeys.cellActions, actions, .OBJC_ASSOCIATION_RETAIN)
      return menu
    }
  }

  extension SidebarContextMenuBuilder {
    /// The "Resync Now (Full History)" item appended to the account menu
    /// for synced accounts. Extracted here (in the type's trailing
    /// helpers block) so `accountMenu(...)` stays inside SwiftLint's
    /// function-body-length budget.
    @MainActor
    private static func resyncMenuItem(target: AccountMenuActions) -> NSMenuItem {
      let item = NSMenuItem(
        title: "Resync Now (Full History)",
        action: #selector(AccountMenuActions.resyncAction(_:)),
        keyEquivalent: "")
      item.target = target
      item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
      item.setAccessibilityIdentifier(UITestIdentifiers.Sidebar.resyncAccountContextMenuItem)
      return item
    }
  }

  /// Target/action sink for the account context menu. Each menu gets
  /// its own instance, retained via `objc_setAssociatedObject` on the
  /// menu (matches the lifetime of the cell it is attached to).
  @MainActor
  private final class AccountMenuActions: NSObject {
    private let onRename: () -> Void
    private let onEdit: () -> Void
    private let onViewTransactions: () -> Void
    private let onResync: () -> Void

    init(
      onRename: @escaping () -> Void,
      onEdit: @escaping () -> Void,
      onViewTransactions: @escaping () -> Void,
      onResync: @escaping () -> Void
    ) {
      self.onRename = onRename
      self.onEdit = onEdit
      self.onViewTransactions = onViewTransactions
      self.onResync = onResync
    }

    @objc
    func renameAction(_ sender: Any?) { onRename() }

    @objc
    func editAction(_ sender: Any?) { onEdit() }

    @objc
    func viewTransactionsAction(_ sender: Any?) { onViewTransactions() }

    @objc
    func resyncAction(_ sender: Any?) { onResync() }
  }

  /// Target/action sink for the earmark and group context menus —
  /// both expose a single "Rename" entry.
  @MainActor
  private final class RenameOnlyMenuActions: NSObject {
    private let onRename: () -> Void

    init(onRename: @escaping () -> Void) {
      self.onRename = onRename
    }

    @objc
    func renameAction(_ sender: Any?) { onRename() }
  }

  @MainActor
  private enum AssociationKeys {
    static var cellActions: UInt8 = 0
  }
#endif
