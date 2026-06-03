/// UI-testing seam payload: a non-optional fixture list wrapped so the store can
/// pass and hold it as an `Optional` (nil = production / preview) without
/// tripping SwiftLint's `discouraged_optional_collection` on a bare
/// `[ScoredInsight]?` init parameter / stored property.
struct InsightFixtures: Sendable {
  let insights: [ScoredInsight]
}
