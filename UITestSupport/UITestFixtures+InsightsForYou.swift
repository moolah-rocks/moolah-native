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

    /// Fixed narration string emitted by `ScriptedNarrator` in the
    /// `.insightsForYouBaseline` seed. Both the app-side override and the
    /// UI-test assertion reference this constant so the two sides can never
    /// drift. Deliberately plain ASCII (no em-dash, currency, or digits) so the
    /// XCUITest label comparison can't trip on accessibility text normalisation.
    public static let scriptedNarration =
      "You made a large purchase at the Apple Store this week."
  }
}
