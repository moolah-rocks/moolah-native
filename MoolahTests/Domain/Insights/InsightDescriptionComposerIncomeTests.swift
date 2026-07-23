import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer – Income")
struct InsightDescriptionComposerIncomeTests {
  @Test
  func paycheckTimingPatternReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .paycheckTimingPattern, title: "Next pay around Jun 30",
      facts: [
        InsightFact("Source", "Acme Corp"),
        InsightFact("Typical amount", "$3,500.00"),
        InsightFact("Cadence", "fortnightly"),
        InsightFact("Next expected", "Jun 30"),
      ])
    #expect(text == "Your next Acme Corp paycheck of about $3,500.00 should land around Jun 30.")
  }

  @Test
  func incomeStabilityScoreReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .incomeStabilityScore, title: "Your income is very steady",
      facts: [
        InsightFact("Source", "Acme Corp"),
        InsightFact("Stability", "94 /100"),
        InsightFact("Variation", "6%"),
        InsightFact("Payments analysed", "12"),
        InsightFact("History window", "395 days"),
        InsightFact("Cadence", "Monthly"),
      ])
    #expect(
      text
        == "Across 12 monthly payments from Acme Corp in the last 395 days, amounts varied by about 6%."
    )
  }

  @Test
  func missingPaycheckAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .missingPaycheckAlert, title: "Expected pay hasn't arrived",
      facts: [
        InsightFact("Source", "Acme Corp"),
        InsightFact("Expected", "Jun 15"),
        InsightFact("Days overdue", "5"),
        InsightFact("Typical amount", "$3,500.00"),
      ])
    #expect(
      text == "Your Acme Corp paycheck of around $3,500.00 was expected Jun 15 and is 5 days late.")
  }

  @Test
  func missingPaycheckAlertSingularDayReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .missingPaycheckAlert, title: "Expected pay hasn't arrived",
      facts: [
        InsightFact("Source", "Acme Corp"), InsightFact("Expected", "Jun 15"),
        InsightFact("Days overdue", "1"), InsightFact("Typical amount", "$3,500.00"),
      ])
    #expect(
      text == "Your Acme Corp paycheck of around $3,500.00 was expected Jun 15 and is 1 day late.")
  }

  @Test
  func windfallIncomeReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .windfallIncome, title: "Larger-than-usual deposit",
      facts: [
        InsightFact("Source", "Acme Corp"),
        InsightFact("Amount", "$5,000.00"),
        InsightFact("Typical income", "$3,500.00"),
        InsightFact("Baseline deposits", "8"),
        InsightFact("Baseline window", "365 days"),
      ])
    #expect(
      text
        == "You received $5,000.00 from Acme Corp — well above the $3,500.00 median across 8 deposits from the last 365 days."
    )
  }

  @Test
  func payRateChangeUpReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .payRateChange, title: "Your pay went up",
      facts: [
        InsightFact("Source", "Acme Corp"),
        InsightFact("New amount", "$4,000.00"),
        InsightFact("Previous", "$3,500.00"),
        InsightFact("Change", "+14%"),
      ])
    #expect(text == "Your Acme Corp pay rose to $4,000.00 from $3,500.00.")
  }

  @Test
  func payRateChangeDownReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .payRateChange, title: "Your pay dropped",
      facts: [
        InsightFact("Source", "Acme Corp"),
        InsightFact("New amount", "$3,000.00"),
        InsightFact("Previous", "$3,500.00"),
        InsightFact("Change", "−14%"),
      ])
    #expect(text == "Your Acme Corp pay dropped to $3,000.00 from $3,500.00.")
  }
}
