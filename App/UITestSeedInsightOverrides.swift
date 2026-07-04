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
      .transferDetectionBaseline,
      .groupFilterScope,
      .walletHeaderSyncError:
      return nil
    }
  }

  #if DEBUG
    /// Returns a `FixedModelAvailability` for seeds that need deterministic
    /// narration in UI tests. `.insightsForYouBaseline` forces `.available` so
    /// the "Why?" button renders and the scripted narrator is exercised. All
    /// other seeds return `nil` — `ProfileSession.finishInit` then falls through
    /// to `SystemLanguageModelAvailability` (the production path).
    static func availability(for seed: UITestSeed) -> FixedModelAvailability? {
      switch seed {
      case .insightsForYouBaseline:
        return FixedModelAvailability(value: .available)
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
        .transferDetectionBaseline,
        .groupFilterScope,
        .walletHeaderSyncError:
        return nil
      }
    }

    /// Returns a `ScriptedNarrator` for seeds that need deterministic narration
    /// output in UI tests. `.insightsForYouBaseline` emits the shared
    /// `UITestFixtures.InsightsForYou.scriptedNarration` constant so the test
    /// can assert the exact rendered string without a real model. All other
    /// seeds return `nil` — `ProfileSession.finishInit` then uses the narrator
    /// selected by `makeInsightNarrator()`.
    static func narrator(for seed: UITestSeed) -> ScriptedNarrator? {
      switch seed {
      case .insightsForYouBaseline:
        return ScriptedNarrator(
          snapshots: [UITestFixtures.InsightsForYou.scriptedNarration])
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
        .transferDetectionBaseline,
        .groupFilterScope,
        .walletHeaderSyncError:
        return nil
      }
    }
  #endif

  private static var insightsForYouBaselineInsights: [ScoredInsight] {
    let fixtures = UITestFixtures.InsightsForYou.self
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return [
      ScoredInsight(
        insight: Insight(
          id: fixtures.largeTxnId,
          kind: .largeTransactionAnomaly,
          title: fixtures.largeTxnTitle,
          date: now,
          framing: .negative,
          actionability: .review,
          surprise: 0.8,
          monetaryImpact: InstrumentAmount(quantity: -2499, instrument: .AUD),
          references: InsightReferences(
            accountIds: [UITestFixtures.TradeBaseline.checkingAccountId]),
          chart: largeTxnChart(anchoredAt: now)),
        score: 4.2),
      ScoredInsight(
        insight: Insight(
          id: fixtures.priceHikeId,
          kind: .subscriptionPriceHike,
          title: fixtures.priceHikeTitle,
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
          date: now,
          framing: .positive,
          actionability: .informational,
          surprise: 0.3),
        score: 2.0),
    ]
  }

  /// A deterministic six-month bar chart attached to the `largeTxnId` fixture
  /// insight so the `.insightsForYouBaseline` seed yields exactly one charted
  /// row (the inline chart Button + the zoom-to-detail sheet). All points are
  /// derived from the fixed `anchoredAt` date — no `Date()` — so the failure
  /// artefacts stay diffable. The last month spikes to the anomaly value to
  /// mirror what `CategoryAnomalyInsight` would produce; the highlight marks it.
  private static func largeTxnChart(anchoredAt anchor: Date) -> InsightChart {
    let monthlySpend: [Double] = [110, 95, 130, 105, 120, 2499]
    let monthSeconds = 86_400.0 * 30
    let points = monthlySpend.enumerated().map { offset, value in
      InsightChart.Point(
        date: anchor.addingTimeInterval(Double(offset) * monthSeconds), value: value)
    }
    return InsightChart(
      kind: .bar,
      unit: .currency(.AUD),
      series: [
        InsightChart.Series(id: "spend", label: "Spending", role: .primary, points: points)
      ],
      highlight: points.last,
      xAxis: .monthly)
  }
}
