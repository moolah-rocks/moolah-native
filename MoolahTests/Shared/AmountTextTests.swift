import Testing

@testable import Moolah

/// `AmountText.toggledSign(_:)` backs the iOS amount-field `±` keyboard
/// toolbar button. Unlike `TransactionDraft.flipTradePaidDisplaySign(_:)` —
/// a *render* bijection that deliberately keeps `"0"`/`"-0"`/`""` unchanged so
/// no phantom minus appears while a value is being rendered — this is a
/// *user-initiated* toggle: tapping `±` always flips the sign, including
/// setting a leading minus on an empty or zero field so the user can choose
/// the sign before typing digits.
@Suite("AmountText.toggledSign")
struct AmountTextTests {

  @Test("positive value gains a leading minus")
  func positiveGainsMinus() {
    #expect(AmountText.toggledSign("50") == "-50")
    #expect(AmountText.toggledSign("1") == "-1")
    #expect(AmountText.toggledSign("300.00") == "-300.00")
  }

  @Test("negative value loses its leading minus")
  func negativeLosesMinus() {
    #expect(AmountText.toggledSign("-50") == "50")
    #expect(AmountText.toggledSign("-12.34") == "12.34")
    #expect(AmountText.toggledSign("-300.00") == "300.00")
  }

  @Test("zero toggles so the user can set the sign before typing")
  func zeroToggles() {
    #expect(AmountText.toggledSign("0") == "-0")
    #expect(AmountText.toggledSign("-0") == "0")
  }

  @Test("empty field toggles to a lone minus and back")
  func emptyToggles() {
    #expect(AmountText.toggledSign("") == "-")
    #expect(AmountText.toggledSign("-").isEmpty)
  }

  @Test("toggling twice returns the original text")
  func roundTrips() {
    let cases = ["", "-", "0", "-0", "1", "-1", "50", "-50", "10.5", "-10.5", "300.00"]
    for value in cases {
      let roundTripped = AmountText.toggledSign(AmountText.toggledSign(value))
      #expect(
        roundTripped == value,
        "toggle(toggle(\"\(value)\")) yielded \"\(roundTripped)\", expected \"\(value)\"")
    }
  }
}
