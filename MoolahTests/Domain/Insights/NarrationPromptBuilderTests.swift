import Testing

@testable import Moolah

@Suite("NarrationPromptBuilder")
struct NarrationPromptBuilderTests {
  @Test
  func perInsightPromptContainsOnlySuppliedFacts() {
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      detail: "Dining hit $640.00, above your $410.00 median.",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("$640.00"))
    #expect(built.prompt.contains("6-mo median"))
    #expect(built.prompt.contains("Dining is up this month"))
    #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
  }

  @Test
  func perInsightPromptContainsDetailDraft() {
    let detail = "Dining hit $640.00, above your usual $410.00."
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      detail: detail,
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("Draft: \(detail)"))
  }

  @Test
  func perInsightPromptContainsAllFactLabelsAndValues() {
    let facts = [
      InsightFact("This month", "$640.00"),
      InsightFact("6-mo median", "$410.00"),
      InsightFact("Change", "+$230.00"),
    ]
    let req = NarrationRequest.singleInsight(
      title: "Dining is up",
      detail: "Dining is up $230.00 on last month.",
      facts: facts)
    let built = NarrationPromptBuilder.build(req)
    for fact in facts {
      #expect(built.prompt.contains(fact.label))
      #expect(built.prompt.contains(fact.value))
    }
  }

  @Test
  func recapPromptListsEachInsightAndAsksForTwoSentences() {
    let req = NarrationRequest.weeklyRecap(items: [
      .init(
        title: "Net worth crossed $100k",
        detail: "Your net worth hit $101,200.",
        facts: [InsightFact("Now", "$101,200")]),
      .init(
        title: "Dining up",
        detail: "Dining came in at $640.00.",
        facts: [InsightFact("This month", "$640.00")]),
    ])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("Net worth crossed $100k"))
    #expect(built.prompt.contains("$640.00"))
    #expect(built.instructions.localizedCaseInsensitiveContains("two sentences"))
  }

  @Test
  func recapPromptContainsDraftForEachItem() {
    let req = NarrationRequest.weeklyRecap(items: [
      .init(
        title: "Net worth crossed $100k",
        detail: "Your net worth hit $101,200.",
        facts: [InsightFact("Now", "$101,200")]),
      .init(
        title: "Dining up",
        detail: "Dining came in at $640.00.",
        facts: [InsightFact("This month", "$640.00")]),
    ])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("Draft: Your net worth hit $101,200."))
    #expect(built.prompt.contains("Draft: Dining came in at $640.00."))
  }

  @Test
  func instructionsForbidInventingNumbers() {
    let req = NarrationRequest.singleInsight(
      title: "Test",
      detail: "Something happened.",
      facts: [InsightFact("Amount", "$100.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
    #expect(built.instructions.localizedCaseInsensitiveContains("only"))
  }

  @Test
  func instructionsRequireOmittingStatisticalFacts() {
    let req = NarrationRequest.singleInsight(
      title: "Test",
      detail: "Something happened.",
      facts: [InsightFact("Amount", "$100.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(
      built.instructions.localizedCaseInsensitiveContains("z-score")
        || built.instructions.localizedCaseInsensitiveContains("statistical"))
  }

  @Test
  func instructionsEncourageContractions() {
    let req = NarrationRequest.singleInsight(
      title: "Test",
      detail: "Something happened.",
      facts: [InsightFact("Amount", "$100.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.instructions.contains("contractions") || built.instructions.contains("you've"))
  }

  @Test
  func recapInstructionsMentionTwoSentenceRecap() {
    let req = NarrationRequest.weeklyRecap(items: [
      .init(title: "A", detail: "A detail.", facts: [])
    ])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.instructions.localizedCaseInsensitiveContains("two sentences"))
  }

  @Test
  func recapPromptUsesCorrectHighlightWord() {
    let singleItem = NarrationRequest.weeklyRecap(items: [
      .init(title: "Net worth up", detail: "Up.", facts: [])
    ])
    let multiItem = NarrationRequest.weeklyRecap(items: [
      .init(title: "Net worth up", detail: "Up.", facts: []),
      .init(title: "Dining down", detail: "Down.", facts: []),
    ])
    let singleBuilt = NarrationPromptBuilder.build(singleItem)
    let multiBuilt = NarrationPromptBuilder.build(multiItem)
    #expect(singleBuilt.prompt.contains("1 highlight this week"))
    #expect(multiBuilt.prompt.contains("2 highlights this week"))
  }

  @Test
  func allFactsAggregatesAcrossRecapItems() {
    let req = NarrationRequest.weeklyRecap(items: [
      .init(title: "Item A", detail: "A.", facts: [InsightFact("Label A", "100")]),
      .init(title: "Item B", detail: "B.", facts: [InsightFact("Label B", "200")]),
    ])
    let all = req.allFacts
    #expect(all.count == 2)
    #expect(all.contains(InsightFact("Label A", "100")))
    #expect(all.contains(InsightFact("Label B", "200")))
  }

  @Test
  func singleInsightAllFactsReturnsItsOwnFacts() {
    let facts = [InsightFact("Label", "42")]
    let req = NarrationRequest.singleInsight(title: "T", detail: "D.", facts: facts)
    #expect(req.allFacts == facts)
  }
}
