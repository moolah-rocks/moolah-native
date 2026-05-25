import Foundation

extension NavigationDestination {

  /// Assembles a route from the in-window state slices that exist on the
  /// receiving end of `@FocusedSceneValue`. Used by the Handoff publisher
  /// to compute the activity payload.
  ///
  /// Precedence:
  /// 1. If `selectedTransaction` is non-nil, the route is
  ///    `.transaction(id)` regardless of which screen is up.
  /// 2. Otherwise the sidebar's `navigationDestination` is used as the
  ///    base case, with `.analysis` / `.reports` overlaid by their
  ///    params (when supplied).
  /// 3. `nil` sidebar produces `nil` route — no Handoff activity is
  ///    advertised.
  static func from(
    sidebar: SidebarSelection?,
    selectedTransaction: UUID?,
    analysis: AnalysisRouteParams?,
    reports: ReportsRouteParams?
  ) -> NavigationDestination? {
    if let transaction = selectedTransaction {
      return .transaction(transaction)
    }
    guard let sidebar else { return nil }
    switch sidebar {
    case .analysis:
      return .analysis(history: analysis?.history, forecast: analysis?.forecast)
    case .reports:
      return .reports(from: reports?.from, to: reports?.to)
    default:
      return sidebar.navigationDestination
    }
  }
}
