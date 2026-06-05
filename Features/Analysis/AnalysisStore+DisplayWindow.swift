import Foundation

// MARK: - Load window + display clipping

extension AnalysisStore {
  /// Minimum history (months) loaded for the insight engine, regardless of the
  /// Analysis screen's display filter. Three years gives the category-anomaly
  /// detector enough same-month samples to recognise an annual pattern instead
  /// of mis-flagging it as an overspend. A *minimum*, never a cap.
  nonisolated static let insightHistoryFloorMonths = 36

  /// The effective load window in months: the larger of the user's display
  /// filter and the insight floor. `historyMonths == 0` ("All") loads
  /// everything, represented as `Int.max`.
  nonisolated static func effectiveLoadMonths(historyMonths: Int, floorMonths: Int) -> Int {
    historyMonths == 0 ? Int.max : max(historyMonths, floorMonths)
  }
}
