import Testing

@testable import Moolah

@Suite("NumericProvenanceGuard")
struct NumericProvenanceGuardTests {
  private let facts = [InsightFact("This month", "$640.00"), InsightFact("Median", "$410.00")]

  // MARK: - Passing cases

  @Test
  func passesWhenEveryNumberIsSourced() {
    #expect(
      NumericProvenanceGuard.isGrounded(
        "Dining hit $640.00, above your $410.00 median.", facts: facts))
  }

  @Test
  func passesWhenNoNumbersPresent() {
    #expect(NumericProvenanceGuard.isGrounded("Looks good this month.", facts: facts))
  }

  @Test
  func passesWithPercentagePresentInFacts() {
    let pctFacts = [InsightFact("Change", "+12.5%"), InsightFact("Base", "$500.00")]
    #expect(
      NumericProvenanceGuard.isGrounded(
        "Spending rose 12.5% to $500.00 this month.", facts: pctFacts))
  }

  @Test
  func passesWithThousandsSeparatorInFacts() {
    let richFacts = [InsightFact("Net worth", "$101,200.00")]
    #expect(
      NumericProvenanceGuard.isGrounded(
        "Your net worth is now $101,200.00.", facts: richFacts))
  }

  @Test
  func passesWithNegativeAmountMatchingFact() {
    let signed = [InsightFact("Change", "−$640.00")]
    // The generated text uses the same minus sign as the fact value.
    #expect(
      NumericProvenanceGuard.isGrounded("Down −$640.00 this month.", facts: signed))
  }

  @Test
  func passesWhenFactUsesUnicodeMinus_generatedUsesAsciiHyphen() {
    // Detectors emit U+2212; LLMs typically emit ASCII U+002D. Both represent
    // the same negative amount and must compare equal after normalisation.
    let signed = [InsightFact("Change", "−$640.00")]  // U+2212
    #expect(
      NumericProvenanceGuard.isGrounded("Down -$640.00 this month.", facts: signed))  // ASCII -
  }

  @Test
  func passesWithEmptyGeneratedText() {
    #expect(NumericProvenanceGuard.isGrounded("", facts: facts))
  }

  @Test
  func passesWithEmptyFacts() {
    // No numbers in generated text, no facts — trivially grounded.
    #expect(NumericProvenanceGuard.isGrounded("Good news this week.", facts: []))
  }

  // MARK: - Failing cases

  @Test
  func failsOnInventedNumber() {
    #expect(!NumericProvenanceGuard.isGrounded("You spent $700.00 on dining.", facts: facts))
  }

  @Test
  func failsOnFlippedSign() {
    // Fact is −$640.00 (negative) but generated text says +$640.00 (positive).
    let signed = [InsightFact("Change", "−$640.00")]
    #expect(!NumericProvenanceGuard.isGrounded("Up +$640.00 this month.", facts: signed))
  }

  @Test
  func failsWhenNumberPresentButNoFacts() {
    #expect(!NumericProvenanceGuard.isGrounded("You spent $200.00.", facts: []))
  }

  @Test
  func failsOnRoundedNumber() {
    // Facts have $640.00 — generated text rounds to $640, which is a different token.
    // The guard errs toward rejecting: $640 ≠ $640.00 after normalisation.
    #expect(!NumericProvenanceGuard.isGrounded("You spent $640 on dining.", facts: facts))
  }

  @Test
  func failsOnPartialMatch() {
    // $40 appears as a substring of $640.00 but is not a fact value token.
    let smallFacts = [InsightFact("Tip", "$40.00")]
    #expect(!NumericProvenanceGuard.isGrounded("You spent $640.00 total.", facts: smallFacts))
  }
}
