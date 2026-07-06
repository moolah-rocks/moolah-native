import Foundation
import Testing

@testable import Moolah

/// Ledger-sourced edge cases for `compute` — each pinned in its own test so a
/// regression reads as a single named failure. Amount invested is the remaining
/// cost basis; fiat holds no lots, so these use a stock to have a real baseline.
@Suite("AccountPerformanceCalculator.compute edge cases")
struct AccountPerformanceEdgeCaseTests {
  private let aud = Instrument.AUD
  private let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  private let account = UUID()
  private let openingDate = Date(timeIntervalSinceReferenceDate: 0)
  private var oneYearLater: Date { openingDate.addingTimeInterval(365 * 86_400) }

  private func leg(_ i: Instrument, _ qty: Decimal, _ type: TransactionType) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: i, quantity: qty, type: type)
  }

  private func valued(_ i: Instrument, quantity: Decimal, worth: Decimal) -> ValuedPosition {
    ValuedPosition(
      instrument: i, quantity: quantity, unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: worth, instrument: aud))
  }

  private func buildLedger(_ txns: [Transaction]) async throws -> HoldingsCostLedger {
    try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
  }

  /// Empty account: no lots, no flows, no value → all zeros, nil percentages.
  @Test("empty account with no flows reports all zeros and nil percentages")
  func emptyAccountNoFlows() async throws {
    let ledger = try await buildLedger([])
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account, valuedPositions: [], profileCurrency: aud, ledger: ledger)
    #expect(perf.currentValue == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.amountInvested == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
    #expect(perf.firstFlowDate == nil)
  }

  /// A buy with no growth: gain = 0, gain% = 0, annualised = 0.
  @Test("buy with no growth reports zero gain, zero percent, zero annualised")
  func buyNoGrowth() async throws {
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -10_000, .trade), leg(bhp, 100, .trade)])
    let ledger = try await buildLedger([buy])
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(bhp, quantity: 100, worth: 10_000)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    #expect(perf.currentValue == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.amountInvested == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLossPercent == 0)
    let annualised = try #require(perf.annualisedReturn)
    #expect(abs(Double(truncating: annualised as NSDecimalNumber)) < 0.001)
  }

  /// Buy then a full disposal a year later, V=0: every lot consumed → remaining
  /// invested 0 and gain 0.
  @Test("buy then full disposal yields zero invested and zero gain")
  func buyThenFullDisposal() async throws {
    let sellDate = openingDate.addingTimeInterval(365 * 86_400)
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -1_000, .trade), leg(bhp, 100, .trade)])
    let sell = Transaction(
      date: sellDate, legs: [leg(bhp, -100, .trade), leg(aud, 1_000, .trade)])
    let ledger = try await buildLedger([buy, sell])
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(bhp, quantity: 0, worth: 0)],
      profileCurrency: aud, ledger: ledger, now: sellDate)
    #expect(perf.currentValue == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.amountInvested == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.firstFlowDate == openingDate)
  }

  /// First flow under one day before `now`: invested / gain / gain% are all
  /// defined (gain% is a simple ratio, not time-weighted), but the annualised
  /// return is nil — `IRRSolver` cannot annualise a sub-day span.
  @Test("first flow under one day old: gain percent defined, annualised nil")
  func firstFlowSubDaySpan() async throws {
    let now = openingDate.addingTimeInterval(60 * 60)  // one hour later
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -1_000, .trade), leg(bhp, 10, .trade)])
    let ledger = try await buildLedger([buy])
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(bhp, quantity: 10, worth: 1_010)],
      profileCurrency: aud, ledger: ledger, now: now)
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_010, instrument: aud))
    #expect(perf.amountInvested == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 10, instrument: aud))
    // Gain% is gain/invested (10/1000) — defined regardless of span; only the
    // annualised rate needs a >= 1-day span.
    #expect(perf.profitLossPercent == Decimal(10) / Decimal(1_000))
    #expect(perf.annualisedReturn == nil)
  }
}
