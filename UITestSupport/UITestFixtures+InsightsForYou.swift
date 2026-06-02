import Foundation

extension UITestFixtures {
  /// Deterministic constants for the `.insightsForYouBaseline` seed. Shared
  /// between the app target (which constructs the `ScoredInsight` values) and
  /// the UI-test drivers (which assert on the rendered titles and identifiers),
  /// so a rename can't desync the two sides. `largeTxnId` references
  /// `UITestFixtures.TradeBaseline.checkingAccountId`, so tapping its "View"
  /// deep-link navigates to that account's detail.
  public enum InsightsForYou {
    public static let largeTxnId = "for-you-large-txn"
    public static let largeTxnTitle = "Large purchase at the Apple Store"
    public static let priceHikeId = "for-you-price-hike"
    public static let priceHikeTitle = "Netflix raised its monthly price"
    public static let milestoneId = "for-you-milestone"
    public static let milestoneTitle = "Net worth crossed a milestone"
  }
}
