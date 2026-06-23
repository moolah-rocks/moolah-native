import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer")
struct InsightDescriptionComposerTests {
  /// Every kind degrades to the bare title when it has no facts — and never
  /// crashes. This invariant must hold for all kinds, now and as arms fill in.
  @Test
  func everyKindDegradesToTitleWithoutFacts() {
    for kind in InsightKind.allCases {
      let text = InsightDescriptionComposer.compose(kind: kind, title: "Headline", facts: [])
      #expect(text == "Headline")
    }
  }

  @Test
  func factLookupFindsByExactLabelAndPrefix() {
    let facts = [InsightFact("Spent (90d)", "$540.00"), InsightFact("Category", "Dining")]
    let lookup = FactLookup(facts)
    #expect(lookup.value("Category") == "Dining")
    #expect(lookup.value("Missing") == nil)
    #expect(lookup.value(prefix: "Spent") == "$540.00")
    #expect(lookup.value(prefix: "Nope") == nil)
  }
}
