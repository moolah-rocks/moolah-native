import Foundation

/// UI-testing-only fixture insights for the `.insightsForYouBaseline` seed.
/// Consulted from `ProfileSession.finishInit` (via
/// `ProfileSession.uiTestingInsightFixtures()`) when launched with
/// `--ui-testing` and the active seed requests deterministic insights instead
/// of live detector output. Nil for every other seed → live `InsightEngine`
/// wiring (mirrors `UITestSeedCryptoOverrides`).
@MainActor
enum UITestSeedInsightOverrides {
  static func fixtures(for seed: UITestSeed) -> InsightFixtures? {
    switch seed {
    case .insightsForYouBaseline:
      return InsightFixtures(insights: insightsForYouBaselineInsights)
    case .tradeBaseline,
      .welcomeEmpty,
      .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles,
      .welcomeDownloading,
      .sidebarFooterUpToDate,
      .sidebarFooterReceiving,
      .sidebarFooterSending,
      .cryptoCatalogPreloaded,
      .tradeReady,
      .incompatibleProfile,
      .pendingWebImportOneChaseInbox,
      .transferDetectionBaseline:
      return nil
    }
  }

  private static var insightsForYouBaselineInsights: [ScoredInsight] {
    let fixtures = UITestFixtures.InsightsForYou.self
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return [
      ScoredInsight(
        insight: Insight(
          id: fixtures.largeTxnId,
          kind: .largeTransactionAnomaly,
          title: fixtures.largeTxnTitle,
          detail: "This is well above your usual spending here.",
          date: now,
          framing: .negative,
          actionability: .review,
          surprise: 0.8,
          monetaryImpact: InstrumentAmount(quantity: -2499, instrument: .AUD),
          references: InsightReferences(
            accountIds: [UITestFixtures.TradeBaseline.checkingAccountId])),
        score: 4.2),
      ScoredInsight(
        insight: Insight(
          id: fixtures.priceHikeId,
          kind: .subscriptionPriceHike,
          title: fixtures.priceHikeTitle,
          detail: "Up $3.00 from last month.",
          date: now,
          framing: .negative,
          actionability: .act,
          surprise: 0.5,
          monetaryImpact: InstrumentAmount(quantity: -3, instrument: .AUD)),
        score: 3.1),
      ScoredInsight(
        insight: Insight(
          id: fixtures.milestoneId,
          kind: .netWorthMilestone,
          title: fixtures.milestoneTitle,
          detail: "Nice work — a new high.",
          date: now,
          framing: .positive,
          actionability: .informational,
          surprise: 0.3),
        score: 2.0),
    ]
  }
}
