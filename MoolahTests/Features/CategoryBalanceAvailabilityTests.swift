import Testing

@testable import Moolah

@Suite("Category balance unavailable presentation")
struct CategoryBalanceAvailabilityTests {
  @Test("recognised permanent conversion failures cannot render partial amounts")
  func unavailableResultHidesAmounts() {
    let partial = InstrumentAmount(quantity: 42, instrument: .defaultTestInstrument)

    #expect(
      CategoryBalanceAvailabilityPresentation.displayedAmount(
        partial, hasUnavailableData: true) == nil)
    #expect(
      CategoryBalanceAvailabilityPresentation.displayedAmount(
        partial, hasUnavailableData: false) == partial)
  }
}
