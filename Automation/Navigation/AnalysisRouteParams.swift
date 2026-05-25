import Foundation

/// Snapshot of the Analysis view's current parameters, published via a
/// `@FocusedSceneValue` so the Handoff publisher (at the window root)
/// can read them without holding a reference to the view's state.
struct AnalysisRouteParams: Hashable, Sendable {
  let history: Int?
  let forecast: Int?
}
