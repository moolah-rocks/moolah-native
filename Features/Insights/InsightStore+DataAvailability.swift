import Foundation

/// Release-safe default that prevents narration from activating unless a real
/// model-availability provider is injected.
struct NeverAvailableModelAvailability: ModelAvailabilityProviding, Sendable {
  @MainActor
  func current() -> ModelAvailability { .unavailable(.deviceNotEligible) }
}

private struct IncompleteInsightDataError: LocalizedError {
  var errorDescription: String? {
    "Some insight data could not be converted. Refresh to try again."
  }
}

extension InsightStore {
  func surfaceIncompleteDataIfNeeded(_ input: InsightInput) {
    guard !input.dataAvailability.isComplete || input.scheduledBillsHaveUnavailableData else {
      return
    }
    let incompleteError = IncompleteInsightDataError()
    logger.warning("\(incompleteError.localizedDescription)")
    hasIncompleteData = true
    error = incompleteError
  }
}
