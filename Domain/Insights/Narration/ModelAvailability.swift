import Foundation

/// Device/runtime eligibility for the on-device language model, mapped off
/// `SystemLanguageModel.default.availability` by the Features-layer adapter so
/// the Domain layer carries no `FoundationModels` dependency. Every Foundation
/// Models touchpoint gates on this (design §"Availability gating").
enum ModelAvailability: Sendable, Hashable {
  case available
  case unavailable(Reason)

  enum Reason: Sendable, Hashable {
    /// Hardware lacks Apple Intelligence — permanently hide LLM affordances.
    case deviceNotEligible
    /// Eligible but the user hasn't turned Apple Intelligence on — a one-time
    /// nudge to Settings is allowed, then hide.
    case appleIntelligenceNotEnabled
    /// Transient (model downloading / warming) — retry later, never disable.
    case modelNotReady
    /// `@unknown default` from the framework — treat as unavailable.
    case unknown
  }

  /// True only when narration may run.
  var isUsable: Bool { self == .available }

  /// True when re-checking later might flip to `.available`.
  var isTransient: Bool {
    if case .unavailable(.modelNotReady) = self { return true }
    return false
  }
}

/// Narrow seam onto model eligibility, mirroring `InstrumentChangeObserving`.
/// Injected into stores so tests/previews supply a fixed value and never reach
/// for a real model.
protocol ModelAvailabilityProviding: Sendable {
  /// Current eligibility. Cheap to call; implementations may re-read each time
  /// so a transient `.modelNotReady → .available` flip is observed on refresh.
  @MainActor
  func current() -> ModelAvailability
}

#if DEBUG
  /// Test/preview double that returns a caller-supplied `ModelAvailability`
  /// value. Unlike `NeverAvailableModelAvailability` (the production fallback,
  /// always `.unavailable(.deviceNotEligible)`), this double lets tests and
  /// previews supply **any** value — including `.available` — to exercise both
  /// the eligible and ineligible branches without reaching for a real model.
  struct FixedModelAvailability: ModelAvailabilityProviding, Sendable {
    let value: ModelAvailability

    @MainActor
    func current() -> ModelAvailability { value }
  }
#endif
