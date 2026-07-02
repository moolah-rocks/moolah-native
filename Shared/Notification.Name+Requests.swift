import Foundation

/// Cross-platform `Notification.Name` constants used by macOS menu-bar
/// commands to request actions from the focused window's views via
/// `.onReceive`. Transaction-list actions (Edit / Delete / Pay) were
/// migrated off this pattern in issue #826 and are now routed through
/// `focusedSceneValue` (see `Shared/FocusedValues.swift`); the names
/// below cover Account / Earmark / Category commands and the Finder
/// "Open with Moolah" CSV pipeline. Future commands should prefer
/// `focusedSceneValue` over a new notification entry — the typed
/// action-binding pattern is `Sendable`-clean and per-leaf scoped,
/// where notifications are untyped and module-global.
extension Notification.Name {
  // Category commands
  static let requestCategoryEdit = Notification.Name("requestCategoryEdit")

  // Account commands
  static let requestAccountEdit = Notification.Name("requestAccountEdit")
  /// Posted to request an incremental sync of a synced (crypto/exchange)
  /// account. `object` is the account's `UUID`. Posted by the menu-bar
  /// "Sync Now" command; designed so other surfaces (e.g. a sidebar
  /// context-menu item) can route through the same observer.
  static let requestAccountSync = Notification.Name("requestAccountSync")
  /// Posted to request a full re-sync (checkpoint reset) of a synced
  /// (crypto/exchange) account. `object` is the account's `UUID`. Posted
  /// by the menu-bar "Resync Now" command; designed so other surfaces
  /// (e.g. a sidebar context-menu item) can route through the same
  /// observer.
  static let requestAccountResync = Notification.Name("requestAccountResync")

  // Earmark commands
  static let requestEarmarkEdit = Notification.Name("requestEarmarkEdit")
  static let requestEarmarkToggleHidden = Notification.Name("requestEarmarkToggleHidden")

  /// Posted when the app is asked to open a CSV file URL (Finder "Open
  /// With", Dock-icon drop). `object` is the file `URL`. The active
  /// profile's `ContentView` observes this and routes it through
  /// `ImportStore.ingest`.
  static let openCSVFile = Notification.Name("openCSVFile")
}
