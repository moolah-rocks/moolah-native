import Testing

@testable import Moolah

@Suite("InsightDescriptionComposer")
struct InsightDescriptionComposerTests {
  /// Every kind degrades to the bare title when it has no facts — and never
  /// crashes. This invariant must hold for all kinds, now and as arms fill in.
  @Test
  func everyKindDegradesToTitleWithoutFacts() {
    for kind in InsightKind.allCases {
      let text = InsightDescriptionComposer.compose(kind: kind, title: "Headline", facts: [])
      #expect(text == "Headline")
    }
  }

  @Test
  func factLookupFindsByExactLabelAndPrefix() {
    let facts = [InsightFact("Spent (90d)", "$540.00"), InsightFact("Category", "Dining")]
    let lookup = FactLookup(facts)
    #expect(lookup.value("Category") == "Dining")
    #expect(lookup.value("Missing") == nil)
    #expect(lookup.value(prefix: "Spent") == "$540.00")
    #expect(lookup.value(prefix: "Nope") == nil)
  }

  @Test
  func newRecurringDetectedReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .newRecurringDetected, title: "New monthly subscription",
      facts: [InsightFact("Merchant", "Spotify"), InsightFact("Monthly equivalent", "$11.99")])
    #expect(text == "You've started a new Spotify subscription — about $11.99 a month.")
  }

  @Test
  func subscriptionPriceHikeReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionPriceHike, title: "Netflix went up",
      facts: [
        InsightFact("Merchant", "Netflix"), InsightFact("New charge", "$22.99"),
        InsightFact("Previous typical", "$15.99"), InsightFact("Increase", "46%"),
        InsightFact("Extra per month", "$7.00"),
      ])
    #expect(text == "Netflix now costs $22.99 a month — $7.00 more than before, a 46% rise.")
  }

  @Test
  func duplicateSubscriptionReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .duplicateSubscription, title: "Overlapping Streaming subscriptions",
      facts: [
        InsightFact("Category", "Streaming"),
        InsightFact("Services", "Netflix, Disney+"),
        InsightFact("Combined monthly", "$32.98"),
      ])
    #expect(
      text
        == "You're paying for overlapping Streaming subscriptions (Netflix, Disney+) — $32.98 a month combined."
    )
  }

  @Test
  func subscriptionCancellationCandidateReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionCancellationCandidate, title: "Still paying for Gym",
      facts: [
        InsightFact("Merchant", "Gym"), InsightFact("Usual cadence", "every 30 days"),
        InsightFact("Days since last", "65"), InsightFact("Monthly cost", "$40.00"),
      ])
    #expect(
      text
        == "You're still paying $40.00 a month for Gym, but there hasn't been a charge in 65 days."
    )
  }

  @Test
  func subscriptionOverspendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionOverspend, title: "Subscriptions are 8% of income",
      facts: [
        InsightFact("Monthly subscriptions", "$120.00"),
        InsightFact("Share of income", "8%"), InsightFact("Active subscriptions", "6"),
      ])
    #expect(text == "Your 6 subscriptions add up to $120.00 a month — 8% of your income.")
  }

  @Test
  func subscriptionOverspendSingularReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionOverspend, title: "Subscriptions are 5% of income",
      facts: [
        InsightFact("Monthly subscriptions", "$40.00"),
        InsightFact("Share of income", "5%"), InsightFact("Active subscriptions", "1"),
      ])
    #expect(text == "Your 1 subscription adds up to $40.00 a month — 5% of your income.")
  }

  @Test
  func subscriptionCancellationCandidateSingularDayReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .subscriptionCancellationCandidate, title: "Still paying for Gym",
      facts: [
        InsightFact("Merchant", "Gym"), InsightFact("Monthly cost", "$40.00"),
        InsightFact("Days since last", "1"),
      ])
    #expect(
      text == "You're still paying $40.00 a month for Gym, but there hasn't been a charge in 1 day."
    )
  }

  @Test
  func largeTransactionAnomalyReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .largeTransactionAnomaly, title: "Unusually large Dining charge",
      facts: [
        InsightFact("Merchant", "Steakhouse"), InsightFact("Amount", "$450.00"),
        InsightFact("Category", "Dining"), InsightFact("Typical for category", "$200.00"),
        InsightFact("Baseline charges", "18"), InsightFact("Baseline window", "365 days"),
      ])
    #expect(
      text
        == "A $450.00 charge from Steakhouse stands out against 18 Dining charges from the last 365 days, whose median was $200.00."
    )
  }

  @Test
  func newMerchantAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .newMerchantAlert, title: "First charge from Acme",
      facts: [
        InsightFact("Merchant", "Acme"), InsightFact("Amount", "$80.00"),
        InsightFact("Merchant history", "395 days"),
      ])
    #expect(text == "Your first charge from Acme in the last 395 days came in at $80.00.")
  }

  @Test
  func unusualDaySpendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unusualDaySpend, title: "Big spending Monday",
      facts: [
        InsightFact("Day", "Monday"), InsightFact("Date", "Monday, Jun 22"),
        InsightFact("Spent", "$300.00"),
        InsightFact("Typical Monday", "$95.00"), InsightFact("Multiple", "3.2×"),
        InsightFact("Comparable days", "12"),
      ])
    #expect(
      text
        == "You spent $300.00 on Monday, Jun 22 — around 3.2× the $95.00 median across 12 other Mondays in your recorded history."
    )
  }

  @Test
  func categorySpendingAnomalyReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categorySpendingAnomaly, title: "Dining up 56% in June",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("Month", "June 2026"),
        InsightFact("Spent", "$640.00"),
        InsightFact("Expected", "$410.00"), InsightFact("Over by", "56%"),
        InsightFact("Series months", "6"),
      ])
    #expect(
      text
        == "Dining spending reached $640.00 in June 2026 — 56% above the $410.00 estimate based on 6 financial-month observations through June 2026."
    )
  }

  @Test
  func categoryTrendRisingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryTrendRising, title: "Groceries spend rising",
      facts: [
        InsightFact("Category", "Groceries"), InsightFact("Direction", "Rising"),
        InsightFact("Per month", "$45.00"), InsightFact("Months analysed", "6"),
        InsightFact("Through month", "June 2026"),
      ])
    #expect(
      text
        == "Over the 6 months through June 2026, Groceries spending rose by about $45.00 a month."
    )
  }

  @Test
  func categoryTrendFallingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryTrendFalling, title: "Transport spend is trending down",
      facts: [
        InsightFact("Category", "Transport"), InsightFact("Direction", "Falling"),
        InsightFact("Per month", "$30.00"), InsightFact("Months analysed", "6"),
        InsightFact("Through month", "June 2026"),
      ])
    #expect(
      text
        == "Over the 6 months through June 2026, Transport spending fell by about $30.00 a month.")
  }

  @Test
  func monthOverMonthDeltaUpReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .monthOverMonthDelta, title: "Spending up 30% vs last month",
      facts: [
        InsightFact("Latest month", "June 2026"), InsightFact("Latest spend", "$2,600.00"),
        InsightFact("Previous month", "May 2026"), InsightFact("Previous spend", "$2,000.00"),
        InsightFact("Change", "+30%"),
      ])
    #expect(text == "You spent $2,600.00 in June 2026, up 30% from $2,000.00 in May 2026.")
  }

  @Test
  func monthOverMonthDeltaDownReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .monthOverMonthDelta, title: "Spending down 30% vs last month",
      facts: [
        InsightFact("Latest month", "June 2026"), InsightFact("Latest spend", "$1,400.00"),
        InsightFact("Previous month", "May 2026"), InsightFact("Previous spend", "$2,000.00"),
        InsightFact("Change", "−30%"),
      ])
    #expect(text == "You spent $1,400.00 in June 2026, down 30% from $2,000.00 in May 2026.")
  }

  @Test
  func categoryMixShiftReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryMixShift, title: "Dining is now 35% of your spending",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("Current share", "35%"),
        InsightFact("Change", "+8 percentage points"), InsightFact("Month", "June 2026"),
        InsightFact("Previous month", "May 2026"),
      ])
    #expect(
      text
        == "Dining made up 35% of your spending in June 2026, up 8 percentage points from May 2026."
    )
  }

  @Test
  func upcomingBillWarningWithBillReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .upcomingBillWarning, title: "Low balance coming up",
      facts: [
        InsightFact("Lowest projected", "$120.00"), InsightFact("On", "Jun 15"),
        InsightFact("Upcoming bill", "Rent $1,500.00"),
      ])
    #expect(text == "Your balance is set to dip to $120.00 around Jun 15, after Rent $1,500.00.")
  }

  @Test
  func upcomingBillWarningWithoutBillReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .upcomingBillWarning, title: "Low balance coming up",
      facts: [InsightFact("Lowest projected", "$120.00"), InsightFact("On", "Jun 15")])
    #expect(text == "Your balance is set to dip to $120.00 around Jun 15.")
  }

  @Test
  func projectedMonthEndBalanceReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .projectedMonthEndBalance, title: "On track to end the month around $3,200",
      facts: [
        InsightFact("Projected balance", "$3,200"), InsightFact("Month", "June 2026"),
      ])
    #expect(text == "You're on track to finish June 2026 with about $3,200.")
  }

  @Test
  func runwayEstimateReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .runwayEstimate, title: "4 months of runway",
      facts: [
        InsightFact("Available funds", "$8,000.00"), InsightFact("Monthly burn", "$2,000.00"),
        InsightFact("Runway", "4 months"), InsightFact("Baseline months", "6"),
      ])
    #expect(
      text
        == "Based on your last 6 complete financial months, a $2,000.00 monthly burn means your $8,000.00 would cover roughly 4 months."
    )
  }
}
