import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.computeLegacy")
struct AccountPerformanceCalculatorLegacyTests {
  let aud = Instrument.AUD

  /// $10,000 invested a year before `now`, latest valuation $11,000 →
  /// contributions $10,000, P/L $1,000, p.a. ≈ 10%.
  @Test("single contribution legacy account converges on 10 percent annualised")
  func singleContributionAnnualisedReturn() throws {
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let dailyBalances = [
      AccountDailyBalance(
        date: openingDate,
        balance: InstrumentAmount(quantity: 10_000, instrument: aud))
    ]
    let values = [
      InvestmentValue(
        date: now,
        value: InstrumentAmount(quantity: 11_000, instrument: aud))
    ]
    let perf = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances, values: values, instrument: aud, now: now)

    let annualised = try #require(perf.annualisedReturn)
    let asDouble = Double(truncating: annualised as NSDecimalNumber)
    #expect(abs(asDouble - 0.10) < 0.001, "expected ~0.10, got \(asDouble)")
  }

  /// `currentValue` is a direct pass-through of the latest
  /// `InvestmentValue`; verified separately from the flow-derived fields.
  @Test("legacy account terminal value is the latest InvestmentValue")
  func legacyTerminalValueIsLatestInvestmentValue() {
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let dailyBalances = [
      AccountDailyBalance(
        date: openingDate,
        balance: InstrumentAmount(quantity: 10_000, instrument: aud))
    ]
    let values = [
      InvestmentValue(
        date: now,
        value: InstrumentAmount(quantity: 11_000, instrument: aud))
    ]
    let perf = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances, values: values, instrument: aud, now: now)

    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
  }

  /// `amountInvested` and `profitLoss` derive from the same flow
  /// arithmetic and break together; tested in one body.
  @Test("legacy single contribution records contributions and P/L")
  func legacySingleContributionContributionsAndProfitLoss() {
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let dailyBalances = [
      AccountDailyBalance(
        date: openingDate,
        balance: InstrumentAmount(quantity: 10_000, instrument: aud))
    ]
    let values = [
      InvestmentValue(
        date: now,
        value: InstrumentAmount(quantity: 11_000, instrument: aud))
    ]
    let perf = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances, values: values, instrument: aud, now: now)

    #expect(perf.amountInvested == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
  }

  /// Empty values array → unavailable performance (no terminal value to
  /// anchor any of the fields against).
  @Test("empty values yields unavailable performance")
  func emptyValuesUnavailable() {
    let perf = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: [], values: [], instrument: aud, now: Date(timeIntervalSinceReferenceDate: 0))
    #expect(perf == AccountPerformance.unavailable(in: aud))
  }
}
