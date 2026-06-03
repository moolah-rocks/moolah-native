import Testing

@testable import Moolah

@Suite("ModelAvailability")
struct ModelAvailabilityTests {
  @Test func onlyAvailableIsUsable() {
    #expect(ModelAvailability.available.isUsable)
    #expect(!ModelAvailability.unavailable(.deviceNotEligible).isUsable)
    #expect(!ModelAvailability.unavailable(.appleIntelligenceNotEnabled).isUsable)
    #expect(!ModelAvailability.unavailable(.modelNotReady).isUsable)
  }

  @Test func modelNotReadyIsTransient() {
    #expect(ModelAvailability.unavailable(.modelNotReady).isTransient)
    #expect(!ModelAvailability.unavailable(.deviceNotEligible).isTransient)
  }

  @Test @MainActor func fixedAvailabilityReturnsConfiguredValue() {
    let fixed = FixedModelAvailability(value: .available)
    #expect(fixed.current() == .available)

    let fixed2 = FixedModelAvailability(value: .unavailable(.deviceNotEligible))
    #expect(fixed2.current() == .unavailable(.deviceNotEligible))
  }
}
