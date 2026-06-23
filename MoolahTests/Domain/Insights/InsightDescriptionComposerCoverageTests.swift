import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer – Coverage")
struct InsightDescriptionComposerCoverageTests {
  @Test
  func groupSpendConcentrationReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .groupSpendConcentration, title: "Most spending runs through Daily Spending",
      facts: [
        InsightFact("Group", "Daily Spending"), InsightFact("Share of spend", "65%"),
        InsightFact("Spent", "$3,250.00"),
      ])
    #expect(text == "65% of your spending — $3,250.00 — runs through Daily Spending.")
  }

  @Test
  func uncategorizedBacklogReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .uncategorizedBacklog, title: "23 transactions need a category",
      facts: [InsightFact("Uncategorized", "23")])
    #expect(text == "You've got 23 transactions waiting for a category.")
  }

  @Test
  func unreconciledTransfersReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unreconciledTransfers, title: "4 transfers to review and merge",
      facts: [InsightFact("Pending transfers", "4")])
    #expect(text == "There are 4 possible transfers to review and merge.")
  }

  @Test
  func lapsedMerchantReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .lapsedMerchant, title: "No recent payments to Corner Cafe",
      facts: [InsightFact("Merchant", "Corner Cafe"), InsightFact("Days since last", "90")])
    #expect(text == "You haven't paid Corner Cafe in 90 days.")
  }

  @Test
  func lapsedMerchantSingularDayReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .lapsedMerchant, title: "No recent payments to Corner Cafe",
      facts: [InsightFact("Merchant", "Corner Cafe"), InsightFact("Days since last", "1")])
    #expect(text == "You haven't paid Corner Cafe in 1 day.")
  }

  @Test
  func uncategorizedBacklogSingularReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .uncategorizedBacklog, title: "1 transactions need a category",
      facts: [InsightFact("Uncategorized", "1")])
    #expect(text == "You've got 1 transaction waiting for a category.")
  }

  @Test
  func unreconciledTransfersSingularReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unreconciledTransfers, title: "1 transfers to review and merge",
      facts: [InsightFact("Pending transfers", "1")])
    #expect(text == "There is 1 possible transfer to review and merge.")
  }

  @Test
  func weekendSpendSkewReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .weekendSpendSkew, title: "Weekends are your big spend days",
      facts: [
        InsightFact("Avg weekend day", "$150.00"), InsightFact("Avg weekday", "$60.00"),
        InsightFact("Ratio", "2.5×"),
      ])
    #expect(
      text == "You spend more on weekends — about $150.00 a weekend day versus $60.00 on weekdays.")
  }

  @Test
  func unbudgetedCategoryReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unbudgetedCategory, title: "Dining has no budget",
      facts: [InsightFact("Category", "Dining"), InsightFact("Spent (90d)", "$540.00")])
    #expect(text == "Dining has no budget yet — you've spent $540.00 there recently.")
  }
}
