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
}
