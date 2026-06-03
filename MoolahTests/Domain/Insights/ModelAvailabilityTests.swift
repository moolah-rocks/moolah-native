import Testing

@testable import Moolah

@Suite("ModelAvailability")
struct ModelAvailabilityTests {
  @Test
  func onlyAvailableIsUsable() {
    #expect(ModelAvailability.available.isUsable)
    #expect(!ModelAvailability.unavailable(.deviceNotEligible).isUsable)
    #expect(!ModelAvailability.unavailable(.appleIntelligenceNotEnabled).isUsable)
    #expect(!ModelAvailability.unavailable(.modelNotReady).isUsable)
  }

  @Test
  func modelNotReadyIsTransient() {
    #expect(ModelAvailability.unavailable(.modelNotReady).isTransient)
    #expect(!ModelAvailability.unavailable(.deviceNotEligible).isTransient)
  }

  @Test
  @MainActor
  func fixedAvailabilityReturnsConfiguredValue() {
    #expect(FixedModelAvailability(value: .available).current() == .available)
    #expect(
      FixedModelAvailability(value: .unavailable(.deviceNotEligible)).current()
        == .unavailable(.deviceNotEligible))
  }
}
