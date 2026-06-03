import FoundationModels

/// Maps the live `SystemLanguageModel.default.availability` onto the domain
/// `ModelAvailability`. The only production reader of the framework's
/// availability API; everything downstream consumes the domain enum.
///
/// Case names confirmed against the installed SDK (Xcode 26.4):
/// `.available`, `.unavailable(.deviceNotEligible)`,
/// `.unavailable(.appleIntelligenceNotEnabled)`, `.unavailable(.modelNotReady)`.
struct SystemLanguageModelAvailability: ModelAvailabilityProviding, Sendable {
  @MainActor
  func current() -> ModelAvailability {
    switch SystemLanguageModel.default.availability {
    case .available:
      return .available
    case .unavailable(.deviceNotEligible):
      return .unavailable(.deviceNotEligible)
    case .unavailable(.appleIntelligenceNotEnabled):
      return .unavailable(.appleIntelligenceNotEnabled)
    case .unavailable(.modelNotReady):
      return .unavailable(.modelNotReady)
    @unknown default:
      return .unavailable(.unknown)
    }
  }
}
