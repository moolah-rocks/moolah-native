import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer – Budgets")
struct InsightDescriptionComposerBudgetsTests {
  @Test
  func earmarkBurndownProjectionReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .earmarkBurndownProjection, title: "Holiday fund heading over budget",
      facts: [
        InsightFact("Budget", "$800.00"), InsightFact("Spent so far", "$600.00"),
        InsightFact("Projected", "$950.00"), InsightFact("Window elapsed", "50%"),
      ])
    #expect(
      text
        == "Holiday fund heading over budget — you've spent $600.00 of your $800.00 budget and you're on pace for $950.00."
    )
  }

  @Test
  func earmarkUnderspendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .earmarkUnderspend, title: "Room to spare in Groceries",
      facts: [
        InsightFact("Budget", "$500.00"), InsightFact("Spent so far", "$200.00"),
        InsightFact("Projected", "$300.00"), InsightFact("Window elapsed", "60%"),
      ])
    #expect(
      text
        == "Room to spare in Groceries — you've spent $200.00 of $500.00, on pace for just $300.00."
    )
  }

  @Test
  func savingsGoalReachedReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsGoalETA, title: "Car fund goal reached",
      facts: [InsightFact("Goal", "$5,000.00"), InsightFact("Saved", "$5,000.00")])
    #expect(text == "Car fund goal reached — you've saved $5,000.00 toward your $5,000.00 target.")
  }

  @Test
  func savingsGoalETAReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsGoalETA, title: "Car fund: on track for Jun 2026",
      facts: [
        InsightFact("Goal", "$5,000.00"), InsightFact("Saved", "$3,000.00"),
        InsightFact("Progress", "60%"), InsightFact("Projected completion", "Jun 2026"),
      ])
    #expect(text == "Car fund: on track for Jun 2026 — you've saved $3,000.00 of $5,000.00 (60%).")
  }

  @Test
  func savingsGoalProgressReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsGoalETA, title: "Car fund is 60% of the way there",
      facts: [
        InsightFact("Goal", "$5,000.00"), InsightFact("Saved", "$3,000.00"),
        InsightFact("Progress", "60%"),
      ])
    #expect(text == "Car fund is 60% of the way there — $3,000.00 saved toward $5,000.00.")
  }
}
