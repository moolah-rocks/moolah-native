import Foundation
import Testing

@testable import Moolah

/// Rule 11 propagation through `ProfitLossCalculator.compute(ledger:)`: an
/// instrument whose cost-basis history hit an unresolvable conversion is
/// OMITTED from `rows` (a partial row would look complete) and surfaced in
/// `unavailableInstrumentIds`, while sibling instruments still render. Split
/// into its own `@Suite` file to keep the base P&L suites within
/// `type_body_length`.
@Suite("ProfitLossCalculator — Rule 11 unavailability")
struct ProfitLossCalculatorUnavailabilityTests {
  private let aud = Instrument.fiat(code: "AUD")

  private func date(_ daysFromBase: Int) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: daysFromBase, to: base)
    else {
      fatalError("Could not construct date \(daysFromBase) days from 2024-01-01")
    }
    return result
  }

  @Test
  func unavailableInstrument_rowOmittedAndFlagged_siblingRenders() async throws {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = UUID()
    let txns = [
      // ETH bought with AUD (no conversion) → creates a lot …
      Transaction(
        date: date(0),
        legs: [
          TransactionLeg(accountId: account, instrument: aud, quantity: -2_000, type: .trade),
          TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .trade),
        ]),
      // … but a later ETH income receipt needs a market conversion that FAILS
      // → ETH is flagged unavailable, so even its partial (buy) row is omitted.
      Transaction(
        date: date(100),
        legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .income)]),
      // BHP bought with AUD → resolves; valued at asOfDate.
      Transaction(
        date: date(0),
        legs: [
          TransactionLeg(accountId: account, instrument: aud, quantity: -4_000, type: .trade),
          TransactionLeg(accountId: account, instrument: bhp, quantity: 100, type: .trade),
        ]),
    ]
    let service = FakeConversionService.failingInstruments(
      [eth.id], rates: ["ASX:BHP.AX": 50])
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud, conversionService: service)

    let result = try await ProfitLossCalculator.compute(
      ledger: ledger, profileCurrency: aud, conversionService: service, asOfDate: date(365))

    #expect(result.unavailableInstrumentIds.contains(eth.id))  // surfaced as unavailable
    #expect(!result.rows.contains { $0.instrument == eth })  // partial ETH row omitted
    let bhpRow = try #require(result.rows.first { $0.instrument == bhp })
    #expect(bhpRow.currentValue == 5_000)  // sibling still renders (100 × 50)
  }
}
