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
        InsightFact("Category", "Dining"), InsightFact("This month", "$640.00"),
        InsightFact("Expected", "$410.00"), InsightFact("Over by", "56%"),
      ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(
      text == "Your Dining spending hit $640.00 this month — about 56% above your usual $410.00.")
  }
}
