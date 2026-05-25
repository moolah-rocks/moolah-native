import Foundation

extension SidebarSelection {

  /// Pure mapping from a sidebar selection to the equivalent
  /// `NavigationDestination`. Used by Handoff (publishing) and by anything
  /// else that needs a route representation of "where the sidebar is."
  ///
  /// `analysis` and `reports` map to their parameterless forms here;
  /// callers that want to overlay the current screen-level state should
  /// use `NavigationDestination.from(sidebar:selectedTransaction:analysis:reports:)`
  /// instead.
  var navigationDestination: NavigationDestination {
    switch self {
    case .account(let id): .account(id)
    case .earmark(let id): .earmark(id)
    case .allTransactions, .recentlyAdded: .accounts
    case .upcomingTransactions: .upcoming
    case .categories: .categories
    case .reports: .reports(from: nil, to: nil)
    case .analysis: .analysis(history: nil, forecast: nil)
    }
  }
}
