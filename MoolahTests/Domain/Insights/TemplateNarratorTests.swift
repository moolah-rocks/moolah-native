import Testing

@testable import Moolah

@Suite("TemplateNarrator")
struct TemplateNarratorTests {
  @Test
  func singleInsightComposesFromFacts() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      kind: .categorySpendingAnomaly,
      title: "Dining is up this month",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    // Arm not yet implemented (Task 3) and the fact labels here don't match
    // its required labels, so the composer degrades to the title.
    #expect(text == "Dining is up this month")
  }
}
