import Foundation

/// Persisted per-`InsightKind` dismissal tally. Each time the user dismisses
/// an insight, the count for that kind is bumped; `InsightRanker`'s fatigue
/// penalty downranks kinds with a high count, so a kind the user keeps
/// dismissing recedes. There is exactly one record per kind.
///
/// A pure value type — the GRDB row and CloudKit adapter live in the backend
/// layer and never leak here. `id` is the `kind` itself: a dismissal tally is
/// identified by which kind it counts.
struct InsightDismissal {
  let kind: InsightKind
  var count: Int = 0
}

extension InsightDismissal: Identifiable {
  var id: InsightKind { kind }
}

extension InsightDismissal: Sendable {}
extension InsightDismissal: Hashable {}
