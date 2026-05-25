import Foundation

/// A typed navigation intent used by AppleScript (`NavigateCommand`) and App
/// Intents (`OpenAccountIntent`) to drive the UI in-process via
/// `PendingNavigation` / `ScriptingContext.setPendingNavigation`.
enum NavigationDestination: Sendable, Equatable {
  case accounts
  case account(UUID)
  case transaction(UUID)
  case earmarks
  case earmark(UUID)
  case analysis(history: Int?, forecast: Int?)
  case reports(from: Date?, to: Date?)
  case categories
  case upcoming

  /// Maps this destination to the `SidebarSelection` a `ContentView` should
  /// adopt, or `nil` when the destination has no direct sidebar equivalent
  /// (`.accounts`, `.earmarks`, `.transaction` — handled elsewhere by the
  /// consuming view).
  var sidebarSelection: SidebarSelection? {
    switch self {
    case .account(let id): .account(id)
    case .earmark(let id): .earmark(id)
    case .analysis: .analysis
    case .reports: .reports
    case .categories: .categories
    case .upcoming: .upcomingTransactions
    case .accounts, .earmarks, .transaction: nil
    }
  }
}
