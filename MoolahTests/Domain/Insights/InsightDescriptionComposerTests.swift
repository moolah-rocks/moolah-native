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
  func largeTransactionAnomalyReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .largeTransactionAnomaly, title: "Unusually large Dining charge",
      facts: [
        InsightFact("Merchant", "Steakhouse"), InsightFact("Amount", "$450.00"),
        InsightFact("Category", "Dining"), InsightFact("Typical for category", "$200.00"),
      ])
    #expect(
      text
        == "A $450.00 charge from Steakhouse stands out for Dining, where you usually spend around $200.00."
    )
  }

  @Test
  func newMerchantAlertReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .newMerchantAlert, title: "First charge from Acme",
      facts: [InsightFact("Merchant", "Acme"), InsightFact("Amount", "$80.00")])
    #expect(text == "Your first charge from Acme came in at $80.00.")
  }

  @Test
  func unusualDaySpendReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .unusualDaySpend, title: "Big spending Monday",
      facts: [
        InsightFact("Day", "Monday"), InsightFact("Spent", "$300.00"),
        InsightFact("Typical Monday", "$95.00"), InsightFact("Multiple", "3.2×"),
      ])
    #expect(text == "You spent $300.00 on Monday — around 3.2× your usual $95.00.")
  }

  @Test
  func categorySpendingAnomalyReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categorySpendingAnomaly, title: "Dining up 56% in June",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("This month", "$640.00"),
        InsightFact("Expected", "$410.00"), InsightFact("Over by", "56%"),
      ])
    #expect(
      text == "Your Dining spending hit $640.00 this month — about 56% above your usual $410.00.")
  }

  @Test
  func categoryTrendRisingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryTrendRising, title: "Groceries spend rising",
      facts: [
        InsightFact("Category", "Groceries"), InsightFact("Direction", "Rising"),
        InsightFact("Per month", "$45.00"),
      ])
    #expect(text == "Your Groceries spending is trending up, by about $45.00 a month.")
  }

  @Test
  func categoryTrendFallingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryTrendFalling, title: "Transport spend is trending down",
      facts: [
        InsightFact("Category", "Transport"), InsightFact("Direction", "Falling"),
        InsightFact("Per month", "$30.00"),
      ])
    #expect(text == "Your Transport spending is easing off — down about $30.00 a month.")
  }

  @Test
  func monthOverMonthDeltaUpReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .monthOverMonthDelta, title: "Spending up 30% vs last month",
      facts: [
        InsightFact("This period", "$2,600.00"), InsightFact("Comparison", "$2,000.00"),
        InsightFact("Change", "+30%"),
      ])
    #expect(text == "You spent $2,600.00 this period, up 30% from $2,000.00 before.")
  }

  @Test
  func monthOverMonthDeltaDownReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .monthOverMonthDelta, title: "Spending down 30% vs last month",
      facts: [
        InsightFact("This period", "$1,400.00"), InsightFact("Comparison", "$2,000.00"),
        InsightFact("Change", "−30%"),
      ])
    #expect(text == "You spent $1,400.00 this period, down 30% from $2,000.00 before.")
  }

  @Test
  func categoryMixShiftReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .categoryMixShift, title: "Dining is now 35% of your spending",
      facts: [
        InsightFact("Category", "Dining"), InsightFact("Current share", "35%"),
        InsightFact("Change", "+8 pts"),
      ])
    #expect(text == "Dining now makes up 35% of your spending, up 8 pts.")
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
      facts: [InsightFact("Projected balance", "$3,200")])
    #expect(text == "You're on track to finish the month with about $3,200.")
  }

  @Test
  func savingsRateTrendRisingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsRateTrend, title: "Your savings rate is climbing",
      facts: [InsightFact("Current savings rate", "18%"), InsightFact("Direction", "Rising")])
    #expect(text == "Your savings rate is climbing — you're now saving 18% of your income.")
  }

  @Test
  func savingsRateTrendFallingReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .savingsRateTrend, title: "Your savings rate is slipping",
      facts: [InsightFact("Current savings rate", "9%"), InsightFact("Direction", "Falling")])
    #expect(text == "Your savings rate has slipped to 9% of your income.")
  }

  @Test
  func runwayEstimateReadsClearly() {
    let text = InsightDescriptionComposer.compose(
      kind: .runwayEstimate, title: "4 months of runway",
      facts: [
        InsightFact("Available funds", "$8,000.00"), InsightFact("Monthly burn", "$2,000.00"),
        InsightFact("Runway", "4 months"),
      ])
    #expect(text == "At about $2,000.00 a month, your $8,000.00 would cover roughly 4 months.")
  }
}
