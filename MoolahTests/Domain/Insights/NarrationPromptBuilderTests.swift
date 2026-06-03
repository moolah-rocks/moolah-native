import Testing

@testable import Moolah

@Suite("NarrationPromptBuilder")
struct NarrationPromptBuilderTests {
  @Test
  func perInsightPromptContainsOnlySuppliedFacts() {
    let req = NarrationRequest.singleInsight(
      title: "Dining is up this month",
      facts: [InsightFact("This month", "$640.00"), InsightFact("6-mo median", "$410.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("$640.00"))
    #expect(built.prompt.contains("6-mo median"))
    #expect(built.prompt.contains("Dining is up this month"))
    #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
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
      facts: facts)
    let built = NarrationPromptBuilder.build(req)
    for fact in facts {
      #expect(built.prompt.contains(fact.label))
      #expect(built.prompt.contains(fact.value))
    }
  }

  @Test
  func instructionsForbidInventingNumbers() {
    let req = NarrationRequest.singleInsight(
      title: "Test",
      facts: [InsightFact("Amount", "$100.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
    #expect(built.instructions.localizedCaseInsensitiveContains("only"))
  }

  @Test
  func instructionsRequireOmittingStatisticalFacts() {
    let req = NarrationRequest.singleInsight(
      title: "Test",
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
      facts: [InsightFact("Amount", "$100.00")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.instructions.contains("contractions") || built.instructions.contains("you've"))
  }

  @Test
  func singleInsightAllFactsReturnsItsOwnFacts() {
    let facts = [InsightFact("Label", "42")]
    let req = NarrationRequest.singleInsight(title: "T", facts: facts)
    #expect(req.allFacts == facts)
  }

  @Test
  func headlinePromptAsksForSelfSufficientSentence() {
    let req = NarrationRequest.singleInsight(
      title: "Net worth crossed $100k",
      facts: [InsightFact("Now", "$101,200")])
    let built = NarrationPromptBuilder.build(req)
    #expect(built.prompt.contains("Net worth crossed $100k"))
    #expect(built.prompt.contains("$101,200"))
    #expect(built.instructions.localizedCaseInsensitiveContains("do not invent"))
    #expect(built.instructions.localizedCaseInsensitiveContains("on its own"))
  }
}
