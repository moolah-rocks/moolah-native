import Foundation

extension UITestIdentifiers {
  // MARK: - Sidebar

  public enum Sidebar {
    /// Sidebar row for a specific account. `id` is the account's UUID, lowercased.
    ///
    /// The same UUID identifier is applied whether the account renders in
    /// the Current Accounts section or the Investments section — `AccountType`
    /// today is mutually exclusive across the two sections (bank/cc/asset
    /// for Current; investment for Investments). If a future account type
    /// can appear in both sections, switch this to a sectioned namespace
    /// (`sidebar.account.current.<uuid>` vs `sidebar.account.investment.<uuid>`)
    /// to avoid duplicates resolving via `firstMatch`.
    public static func account(_ id: UUID) -> String {
      "sidebar.account.\(id.uuidString.lowercased())"
    }

    /// Sidebar row for a named top-level view (e.g. `"upcoming"`, `"analysis"`).
    public static func view(_ name: String) -> String {
      "sidebar.view.\(name)"
    }

    /// Sidebar row for a specific earmark. `id` is the earmark's UUID,
    /// lowercased. Mirrors the `account(_:)` identifier shape so
    /// drivers can resolve earmark rows by id.
    public static func earmark(_ id: UUID) -> String {
      "sidebar.earmark.\(id.uuidString.lowercased())"
    }

    /// "New Account" toolbar button in the sidebar (macOS only).
    public static let newAccountButton = "sidebar.toolbar.newAccount"

    /// "New Earmark" toolbar button in the sidebar (macOS only). Pinned for
    /// symmetry with `newAccountButton` so a UI test can drive the
    /// create-earmark flow from a zero-earmark seed without further view
    /// changes when one is added.
    public static let newEarmarkButton = "sidebar.toolbar.newEarmark"

    /// "Edit Account…" item in the sidebar account context menu.
    /// Distinct from the menu-bar Account → Edit Account command,
    /// which has the same title but lives in the application menu —
    /// drivers must resolve via this identifier rather than the
    /// shared label.
    public static let editAccountContextMenuItem = "sidebar.contextMenu.editAccount"

    /// "View Transactions" item in the sidebar account context menu.
    /// Selecting it sets the sidebar selection to the corresponding
    /// account row.
    public static let viewTransactionsContextMenuItem = "sidebar.contextMenu.viewTransactions"

    /// "Rename" item in the sidebar context menu for account rows.
    /// Phase 4 will extend this identifier to earmark and account-group
    /// rows; the identifier is centralised here so the same selector
    /// works across all three entity types once they are wired.
    public static let renameContextMenuItem = "sidebar.contextMenu.rename"

    /// "Resync Now (Full History)" item in the sidebar account context
    /// menu. Present only for synced accounts (`AccountType.isSynced` —
    /// crypto or exchange); posts `.requestAccountResync` with the
    /// account's `UUID`, which `SidebarSharedModifiers` observes and
    /// dispatches to `SyncedAccountStore.syncAccount(_:fullResync:
    /// true)`. Shared by both the AppKit (macOS) and SwiftUI (iOS)
    /// sidebar context menus so a single identifier resolves the item
    /// on either platform.
    ///
    /// Currently referenced by `SidebarContextMenuBuilderTests` (a
    /// `MoolahTests` unit test that asserts the AppKit menu item carries
    /// this identifier for synced accounts and is absent otherwise), not
    /// yet by a `MoolahUITests_macOS` driver: the gated visibility and
    /// notification payload are pure orchestration with no focus /
    /// overlay / keyboard component, so per UI_TEST_GUIDE §1 the unit
    /// test is the cheapest sufficient coverage and no XCUITest is
    /// warranted for this task. The identifier is still applied so a
    /// later end-to-end resync UI test can resolve the item without a
    /// further view change.
    public static let resyncAccountContextMenuItem = "sidebar.contextMenu.resyncAccount"

    /// Accessibility identifier on the inline `TextField` rendered while
    /// a sidebar row is being renamed. Used by `SidebarScreen` driver
    /// methods to resolve the field through the `NSHostingView` boundary
    /// without relying on the accessibility label "Name".
    public static let renameNameField = "sidebar.row.renameField"

    /// Sidebar row for a specific account group. `id` is the group's
    /// UUID, lowercased. Distinct namespace from `account(_:)` so a
    /// driver can disambiguate group-vs-account rows when needed.
    public static func group(_ id: UUID) -> String {
      "sidebar.group.\(id.uuidString.lowercased())"
    }

    /// The "Group" submenu trigger inside the account context menu.
    /// Submenu items are matched by their visible label (the existing
    /// group names + the literal "New Group…" / "Remove from Group")
    /// rather than by identifier so they remain dynamic.
    public static let groupSubmenu = "sidebar.contextMenu.groupSubmenu"
  }
}
