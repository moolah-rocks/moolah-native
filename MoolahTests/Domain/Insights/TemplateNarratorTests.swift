import Testing

@testable import Moolah

@Suite("TemplateNarrator")
struct TemplateNarratorTests {
  @Test
  func singleInsightEmitsSingleSnapshot() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text.contains("Dining is up this month"))
    #expect(text.contains("This month"))
    #expect(text.contains("$640.00"))
    #expect(text.contains("6-mo median"))
    #expect(text.contains("$410.00"))
  }

  @Test
  func recapComposesAcrossItems() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.weeklyRecap(items: [
      .init(title: "Net worth crossed $100k", facts: [InsightFact("Now", "$101,200")]),
      .init(title: "Dining up", facts: [InsightFact("This month", "$640.00")]),
    ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text.contains("Net worth crossed $100k"))
    #expect(text.contains("$101,200"))
    #expect(text.contains("Dining up"))
    #expect(text.contains("$640.00"))
  }

  @Test
  func emptyFactsStillProducesTitle() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.singleInsight(title: "Something happened", facts: [])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text.contains("Something happened"))
  }
}
