import Foundation

extension InsightStore {
  /// Display-history persistence must not blank an otherwise valid insight
  /// batch. Surface a write failure for diagnostics while leaving the freshly
  /// published recommendations visible.
  func recordShown(_ presentationKeys: Set<String>, at date: Date) async {
    do {
      try await displayHistoryRepository.recordShown(presentationKeys, at: date)
    } catch {
      surface(error: error)
    }
  }

  func loadDisplayHistory() async -> [String: Date] {
    do {
      return try await displayHistoryRepository.fetchLastShown()
    } catch {
      surface(error: error)
      return [:]
    }
  }
}
