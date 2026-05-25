import Foundation

/// Snapshot of the Reports view's current date range, published via a
/// `@FocusedSceneValue` so the Handoff publisher (at the window root)
/// can read it without holding a reference to the view's state.
struct ReportsRouteParams: Hashable, Sendable {
  let from: Date?
  let to: Date?
}
