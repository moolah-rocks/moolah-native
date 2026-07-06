import Foundation
import Testing

@testable import Moolah

/// `compute` reads the shared `HoldingsCostLedger`: the "Amount invested" tile
/// (`amountInvested`) is the remaining cost basis (a stock), gain is
/// `value − invested`, and the annualised return is the IRR over the ledger's
/// market-valued flows. Fiat legs create no lots, so these fixtures use a stock
/// / crypto to exercise a real invested figure.
@Suite("AccountPerformanceCalculator.compute")
struct AccountPerformanceCalculatorTests {
  private let aud = Instrument.AUD
  private let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
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

  private func buildLedger(
    _ txns: [Transaction], service: any InstrumentConversionService
  ) async throws -> HoldingsCostLedger {
    try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud, conversionService: service)
  }

  /// A same-account stock buy now establishes an invested baseline: the
  /// acquisition's remaining cost basis is the amount invested and gain is
  /// value − that. (Under the old boundary-crossing model an intra-account
  /// trade produced no flow, painting the whole value as "free" gain.)
  @Test("fiat-paired buy: invested is remaining cost basis, gain is value minus it")
  func fiatPairedBuyInvestedAndGain() async throws {
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -4_000, .trade), leg(bhp, 100, .trade)])
    let ledger = try await buildLedger([buy], service: FakeConversionService.fixedRates([:]))
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(bhp, quantity: 100, worth: 5_000)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    #expect(perf.currentValue == InstrumentAmount(quantity: 5_000, instrument: aud))
    #expect(perf.amountInvested == InstrumentAmount(quantity: 4_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.firstFlowDate == openingDate)
  }

  /// Gain percent is the simple total return on invested capital
  /// (`gain / amountInvested`), decoupled from the IRR.
  @Test("gain percent is gain over amount invested")
  func gainPercentIsGainOverInvested() async throws {
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -4_000, .trade), leg(bhp, 100, .trade)])
    let ledger = try await buildLedger([buy], service: FakeConversionService.fixedRates([:]))
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(bhp, quantity: 100, worth: 5_000)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    let percent = try #require(perf.profitLossPercent)
    #expect(percent == Decimal(1_000) / Decimal(4_000))  // 1000 gain on 4000 invested = 0.25
  }

  /// 25% growth over exactly one year → ~0.25 annualised IRR over the single
  /// +4,000 acquisition inflow, terminal 5,000.
  @Test("annualised return is the IRR over the acquisition inflow")
  func annualisedReturnOverOneYear() async throws {
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -4_000, .trade), leg(bhp, 100, .trade)])
    let ledger = try await buildLedger([buy], service: FakeConversionService.fixedRates([:]))
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(bhp, quantity: 100, worth: 5_000)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    let annualised = try #require(perf.annualisedReturn)
    let asDouble = Double(truncating: annualised as NSDecimalNumber)
    #expect(abs(asDouble - 0.25) < 0.001, "expected ~0.25, got \(asDouble)")
  }

  /// A received (airdropped) crypto's amount invested is its AUD market value
  /// on receipt — the received-token = inflow-at-market rule — so a receive-only
  /// wallet gets a finite return where the old contributions path produced none.
  @Test("crypto receipt: invested is market value on receipt, return is finite")
  func cryptoReceiptInvestedIsMarketValue() async throws {
    let receive = Transaction(date: openingDate, legs: [leg(eth, 1, .income)])
    let ledger = try await buildLedger(
      [receive], service: FakeConversionService.fixedRates([eth.id: 4_000]))
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(eth, quantity: 1, worth: 6_000)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    #expect(perf.amountInvested == InstrumentAmount(quantity: 4_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 2_000, instrument: aud))
    let annualised = try #require(perf.annualisedReturn)
    #expect(Double(truncating: annualised as NSDecimalNumber) > 0)
  }

  /// A disposal consumes lots FIFO, so the remaining cost basis (amount
  /// invested) drops to the cost of the lots still held.
  @Test("disposal reduces remaining amount invested to the held lots' cost")
  func disposalReducesRemainingInvested() async throws {
    let sellDate = openingDate.addingTimeInterval(30 * 86_400)
    let buy = Transaction(date: openingDate, legs: [leg(aud, -4_000, .trade), leg(eth, 2, .trade)])
    let sell = Transaction(date: sellDate, legs: [leg(eth, -1, .trade), leg(aud, 3_000, .trade)])
    let ledger = try await buildLedger([buy, sell], service: FakeConversionService.fixedRates([:]))
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(eth, quantity: 1, worth: 3_500)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    // Bought 2 ETH @ 2,000; sold 1 (FIFO) → 1 ETH @ 2,000 remains invested.
    #expect(perf.amountInvested == InstrumentAmount(quantity: 2_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_500, instrument: aud))  // 3500 − 2000
  }

  /// A genuine conversion failure marks the affected instrument unavailable in
  /// the ledger (Rule 11): amount invested and gain become nil, but the
  /// already-valued current value still shows. The calculator does not throw —
  /// the failure is encoded in the pre-built ledger, not raised here.
  @Test("genuine conversion failure marks invested unavailable, value survives")
  func conversionFailureMarksInvestedUnavailable() async throws {
    let receive = Transaction(date: openingDate, legs: [leg(eth, 1, .income)])
    let ledger = try await buildLedger(
      [receive], service: FakeConversionService.failingInstruments([eth.id]))
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: [valued(eth, quantity: 1, worth: 6_000)],
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    #expect(perf.currentValue == InstrumentAmount(quantity: 6_000, instrument: aud))
    #expect(perf.amountInvested == nil)
    #expect(perf.profitLoss == nil)
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
  }

  /// V_now unavailable (a position's `value` is nil) → currentValue / profitLoss
  /// / percentages / annualised all require V and stay nil, but the amount
  /// invested (a pure ledger read) and first-flow date survive.
  @Test("missing position value yields a partial performance")
  func missingPositionValuePartialShape() async throws {
    let buy = Transaction(
      date: openingDate, legs: [leg(aud, -1_000, .trade), leg(bhp, 10, .trade)])
    let ledger = try await buildLedger([buy], service: FakeConversionService.fixedRates([:]))
    let valuedNil = [
      ValuedPosition(instrument: bhp, quantity: 10, unitPrice: nil, costBasis: nil, value: nil)
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: account,
      valuedPositions: valuedNil,
      profileCurrency: aud, ledger: ledger, now: oneYearLater)
    #expect(perf.currentValue == nil)
    #expect(perf.amountInvested == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == nil)
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
    #expect(perf.firstFlowDate == openingDate)
  }
}
