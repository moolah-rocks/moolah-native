/// One ready-to-render For You entry: the ranked insight plus its resolved
/// display headline (the on-device AI line, or the detector `title` fallback).
struct ForYouItem: Identifiable, Sendable, Hashable {
  let scored: ScoredInsight
  let headline: String
  var id: String { scored.id }
}
