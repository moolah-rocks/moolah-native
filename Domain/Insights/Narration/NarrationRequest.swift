import Foundation

/// The sole input to any narrator. Built from pre-formatted `InsightFact` values
/// so the language model never receives raw transactions or unformatted amounts
/// (zero-hallucination seam, issue #1042).
enum NarrationRequest: Sendable, Hashable {
  /// A single insight to narrate in one or two sentences.
  case singleInsight(kind: InsightKind, title: String, facts: [InsightFact])

  /// Every fact across the request, in presentation order. Used by the numeric
  /// provenance guard to verify that all numbers in the generated text were
  /// supplied verbatim here — never invented by the model.
  var allFacts: [InsightFact] {
    switch self {
    case .singleInsight(_, _, let facts):
      return facts
    }
  }

  /// The detector title, surfaced for the provenance guard's grounding set.
  /// The redesigned headline replaces the title, so a figure present only in
  /// the title (not the facts) must still be treated as grounded.
  var groundingTitle: String {
    switch self {
    case .singleInsight(_, let title, _):
      return title
    }
  }
}
