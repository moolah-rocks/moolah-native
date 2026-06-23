import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer – Savings & Investments")
struct InsightDescriptionComposerSavingsTests {
  @Test
  func idleCashAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .idleCashAlert, title: "More cash than usual in liquid accounts",
      facts: [
        InsightFact("Available funds", "$20,000.00"),
        InsightFact("Average monthly spend", "$4,000.00"),
        InsightFact("Suggested buffer (3 months' spending)", "$12,000.00"),
        InsightFact("Idle excess", "$8,000.00"),
      ])
    #expect(
      text
        == "You've got $20,000.00 sitting in cash — about $8,000.00 more than you'd typically need on hand."
    )
  }

  @Test
  func feeSpendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .feeSpend, title: "You paid $120.00 in fees",
      facts: [
        InsightFact("Annual fees", "-$120.00"),
        InsightFact("Transactions", "47"),
      ])
    #expect(text == "You paid $120.00 in fees over the past year, across 47 charges.")
  }

  @Test
  func feeSpendSingularChargeReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .feeSpend, title: "You paid $5.00 in fees",
      facts: [InsightFact("Annual fees", "-$5.00"), InsightFact("Transactions", "1")])
    #expect(text == "You paid $5.00 in fees over the past year, across 1 charge.")
  }

  @Test
  func netWorthMilestoneReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .netWorthMilestone, title: "Net worth passed $100,000",
      facts: [
        InsightFact("Net worth", "$104,200"),
        InsightFact("Milestone", "$100,000"),
        InsightFact("Was", "$92,000"),
      ])
    #expect(text == "Your net worth just passed $100,000 and now sits at $104,200.")
  }

  @Test
  func investmentConcentrationRiskReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .investmentConcentrationRisk, title: "AAPL is 42% of your investments",
      facts: [
        InsightFact("Holding", "AAPL"),
        InsightFact("Value", "$21,000.00"),
        InsightFact("Share of portfolio", "42%"),
      ])
    #expect(text == "AAPL now makes up 42% of your investments, worth $21,000.00.")
  }

  @Test
  func topPerformerReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .topPerformer, title: "AAPL is your top performer",
      facts: [
        InsightFact("Holding", "AAPL"),
        InsightFact("Return", "34%"),
        InsightFact("Gain/loss", "$3,400.00"),
        InsightFact("Invested", "$10,000.00"),
      ])
    #expect(
      text == "AAPL is your strongest holding, up 34% for a $3,400.00 gain on $10,000.00 invested.")
  }

  @Test
  func bottomPerformerReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .bottomPerformer, title: "TSLA is lagging",
      facts: [
        InsightFact("Holding", "TSLA"),
        InsightFact("Return", "−12%"),
        InsightFact("Gain/loss", "−$1,200.00"),
        InsightFact("Invested", "$10,000.00"),
      ])
    #expect(text == "TSLA is lagging — −12% on $10,000.00 invested, a −$1,200.00 change.")
  }

  @Test
  func capitalGainsHarvestReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .capitalGainsHarvest, title: "Possible tax-loss offset",
      facts: [
        InsightFact("Realised gains", "$3,000.00"),
        InsightFact("Unrealised losses", "−$2,500.00"),
        InsightFact("Potential offset", "$2,000.00"),
        InsightFact("Loss positions", "TSLA, NVDA"),
      ])
    #expect(
      text
        == "You could offset $2,000.00 of realised gains against unrealised losses in TSLA, NVDA.")
  }
}
