import Testing

@testable import Moolah

@Suite("TemplateNarrator")
struct TemplateNarratorTests {
  @Test
  func singleInsightComposesFromFacts() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      kind: .categorySpendingAnomaly,
      title: "Dining up 56% in June",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("Month", "June 2026"),
        InsightFact("Spent", "$640.00"),
        InsightFact("Expected", "$410.00"), InsightFact("Over by", "56%"),
        InsightFact("Series months", "6"),
      ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(
      text
        == "Dining spending reached $640.00 in June 2026 — 56% above the $410.00 estimate based on 6 financial-month observations through June 2026."
    )
  }
}
