import Foundation

extension UITestFixtures {
  /// Deterministic constants for the `.insightsForYouBaseline` seed. The
  /// `[ScoredInsight]` values live in `App/UITestSeedInsightOverrides` (app
  /// target only); these ids/titles are referenced by both that override and
  /// `ForYouPanelUITests` so a rename can't desync them. The navigable row
  /// references `UITestFixtures.TradeBaseline.checkingAccountId`, so tapping
  /// "View" lands on that account's detail (asserted via its name).
  public enum InsightsForYou {
    public static let largeTxnId = "for-you-large-txn"
    public static let largeTxnTitle = "Large purchase at the Apple Store"
    public static let priceHikeId = "for-you-price-hike"
    public static let priceHikeTitle = "Netflix raised its monthly price"
    public static let milestoneId = "for-you-milestone"
    public static let milestoneTitle = "Net worth crossed a milestone"
  }
}
