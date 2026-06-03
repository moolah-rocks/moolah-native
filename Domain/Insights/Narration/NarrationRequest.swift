import Foundation

/// The sole input to any narrator. Built from pre-formatted `InsightFact` values
/// so the language model never receives raw transactions or unformatted amounts
/// (zero-hallucination seam, issue #1042).
enum NarrationRequest: Sendable, Hashable {
  /// A single insight to narrate in one or two sentences.
  case singleInsight(title: String, facts: [InsightFact])

  /// Every fact across the request, in presentation order. Used by the numeric
  /// provenance guard to verify that all numbers in the generated text were
  /// supplied verbatim here — never invented by the model.
  var allFacts: [InsightFact] {
    switch self {
    case .singleInsight(_, let facts):
      return facts
    }
  }
}
