import Foundation
import Testing

@testable import Moolah

/// Tests for `InstrumentAmount.formattedApproximate` — the ~3 significant-figure
/// ballpark renderer used by cash-flow forecast narration.
///
/// Assertions check the rounded digits, grouping, sign, and the absence of
/// cents — never the currency symbol. `.currency(code:)` renders the symbol per
/// the *current locale* (AUD is "$" on en-AU but "A$" on en-US/CI), so asserting
/// a literal "$" is locale-fragile; the rounding behaviour is what matters.
@Suite("InstrumentAmount.formattedApproximate")
struct InstrumentAmountApproximateTests {
  private let aud = Instrument.AUD

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  @Test("rounds large positive amount to 3 sig figs")
  func largePositive() {
    let result = amount(dec("225460.22")).formattedApproximate
    #expect(result.contains("225,000"))
    #expect(!result.contains("225,460"))  // not the precise value
    #expect(!result.contains(".00"))  // no cents
    #expect(!result.contains("-"))  // positive
  }

  @Test("preserves negative sign")
  func largeNegative() {
    let result = amount(dec("-225460.22")).formattedApproximate
    #expect(result.contains("225,000"))
    #expect(result.contains("-"))  // sign preserved, never abs()-ed
    #expect(!result.contains("225,460"))
  }

  @Test("rounds 4-digit amount correctly")
  func fourDigit() {
    let result = amount(dec("9840")).formattedApproximate
    #expect(result.contains("9,840"))
    #expect(!result.contains(".00"))
  }

  @Test("rounds 3-digit amount (no cents)")
  func threeDigit() {
    let result = amount(dec("512.30")).formattedApproximate
    #expect(result.contains("512"))
    #expect(!result.contains(".30"))  // rounded, cents dropped
    #expect(!result.contains(".00"))
  }

  @Test("zero returns a whole-currency zero")
  func zero() {
    let result = amount(0).formattedApproximate
    #expect(result.contains("0"))
    #expect(!result.contains("."))  // no fractional part
    #expect(!result.contains("-"))
  }
}
