import Foundation

/// Per-profile, per-device history of which semantic insights appeared in the
/// For You card. This is local UI state rather than financial data, so it is
/// intentionally not synced through CloudKit.
protocol InsightDisplayHistoryRepository: Sendable {
  /// Most recent display time keyed by `Insight.presentationKey`.
  func fetchLastShown() async throws -> [String: Date]

  /// Records the visible batch. Implementations keep the newer timestamp when
  /// an older write arrives, making overlapping refresh completion harmless.
  func recordShown(_ presentationKeys: Set<String>, at date: Date) async throws
}
