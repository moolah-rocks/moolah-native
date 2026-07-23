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
        InsightFact("Spent", "$3,250.00"), InsightFact("Window", "30 days"),
      ])
    #expect(
      text
        == "Over the last 30 days, 65% of your spending — $3,250.00 — ran through Daily Spending."
    )
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
        InsightFact("Typical weekend day", "$150.00"), InsightFact("Typical weekday", "$60.00"),
        InsightFact("Ratio", "2.5×"),
        InsightFact("Weekend days analysed", "16"), InsightFact("Weekdays analysed", "42"),
      ])
    #expect(
      text
        == "Across your recorded history, a typical weekend spending day was $150.00, compared with $60.00 on a weekday (16 weekend days and 42 weekdays)."
    )
  }

  @Test
  func unbudgetedCategoryReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unbudgetedCategory, title: "Dining has no budget",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("Spent", "$540.00"),
        InsightFact("Window", "90 days"),
      ])
    #expect(text == "Dining has no budget, despite $540.00 of spending in the last 90 days.")
  }

  @Test
  func savingsRateTrendRisingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsRateTrend, title: "Your savings rate is climbing",
      facts: [
        InsightFact("Current savings rate", "18%"), InsightFact("Direction", "Rising"),
        InsightFact("Months analysed", "6"), InsightFact("Through month", "June 2026"),
      ])
    #expect(
      text == "Across 6 complete months through June 2026, your savings rate climbed to 18%.")
  }

  @Test
  func savingsRateTrendFallingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsRateTrend, title: "Your savings rate is slipping",
      facts: [
        InsightFact("Current savings rate", "9%"), InsightFact("Direction", "Falling"),
        InsightFact("Months analysed", "6"), InsightFact("Through month", "June 2026"),
      ])
    #expect(
      text == "Across 6 complete months through June 2026, your savings rate fell to 9%.")
  }
}
