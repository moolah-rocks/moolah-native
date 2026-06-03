import Testing

@testable import Moolah

@Suite("TemplateNarrator")
struct TemplateNarratorTests {
  @Test
  func singleInsightReturnsDetailString() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      detail: "Dining hit $640.00 this month, well above your usual $410.00.",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text == "Dining hit $640.00 this month, well above your usual $410.00.")
  }

  @Test
  func singleInsightEmptyDetailFallsBackToTitle() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      detail: "",
      facts: [InsightFact("This month", "$640.00")])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text == "Dining is up this month")
  }
}
