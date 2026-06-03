import Foundation
import Testing

@testable import Moolah

/// Tests for `InstrumentAmount.formattedApproximate` — the ~3 significant-figure
/// ballpark renderer used by cash-flow forecast narration.
@Suite("InstrumentAmount.formattedApproximate")
struct InstrumentAmountApproximateTests {
  private let aud = Instrument.AUD

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  @Test("rounds large positive amount to 3 sig figs")
  func largePositive() {
    let result = amount(dec("225460.22")).formattedApproximate
    #expect(result == "$225,000")
  }

  @Test("preserves negative sign")
  func largeNegative() {
    let result = amount(dec("-225460.22")).formattedApproximate
    #expect(result == "-$225,000")
  }

  @Test("rounds 4-digit amount correctly")
  func fourDigit() {
    let result = amount(dec("9840")).formattedApproximate
    #expect(result == "$9,840")
  }

  @Test("rounds 3-digit amount (no cents)")
  func threeDigit() {
    let result = amount(dec("512.30")).formattedApproximate
    #expect(result == "$512")
  }

  @Test("zero returns $0")
  func zero() {
    let result = amount(0).formattedApproximate
    #expect(result == "$0")
  }
}
