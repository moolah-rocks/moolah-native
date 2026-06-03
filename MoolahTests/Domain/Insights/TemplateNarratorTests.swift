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

  @Test
  func recapComposesTitleOnlySentence() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.weeklyRecap(items: [
      .init(
        title: "Net worth crossed $100k",
        detail: "Your net worth hit $101,200.",
        facts: [InsightFact("Now", "$101,200")]),
      .init(
        title: "Dining up",
        detail: "Dining came in at $640.00 this month.",
        facts: [InsightFact("This month", "$640.00")]),
    ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text == "This week: Net worth crossed $100k and Dining up.")
  }

  @Test
  func recapSingleItemGrammar() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.weeklyRecap(items: [
      .init(title: "Net worth up", detail: "Your net worth grew.", facts: [])
    ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text == "This week: Net worth up.")
  }

  @Test
  func recapThreeItemsGrammar() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.weeklyRecap(items: [
      .init(title: "Net worth up", detail: "", facts: []),
      .init(title: "Dining down", detail: "", facts: []),
      .init(title: "Groceries steady", detail: "", facts: []),
    ])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text == "This week: Net worth up, Dining down, and Groceries steady.")
  }

  @Test
  func recapEmptyItemsReturnsEmpty() async throws {
    let narrator = TemplateNarrator()
    let req = NarrationRequest.weeklyRecap(items: [])

    var snapshots: [String] = []
    for try await snapshot in narrator.narrate(req) {
      snapshots.append(snapshot)
    }

    #expect(snapshots.count == 1)
    let text = try #require(snapshots.first)
    #expect(text.isEmpty)
  }
}
