import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout")
struct AccountDetailLayoutTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD

  // MARK: - iOS tab presence / order

  @Test("fiat-only account shows Transactions then Chart, no Positions")
  func fiatOnlyTabs() {
    #expect(AccountDetailLayout.iOSTabs(hasPositions: false) == [.transactions, .chart])
  }

  @Test("multi-instrument account inserts Positions between Transactions and Chart")
  func multiInstrumentTabs() {
    #expect(
      AccountDetailLayout.iOSTabs(hasPositions: true) == [.transactions, .positions, .chart])
  }

  @Test("Transactions is always the first tab (the default selection)")
  func transactionsFirst() {
    #expect(AccountDetailLayout.iOSTabs(hasPositions: false).first == .transactions)
    #expect(AccountDetailLayout.iOSTabs(hasPositions: true).first == .transactions)
  }

  // MARK: - macOS layout shape

  @Test("macOS bottom pane toggle is always Transactions then Chart")
  func macBottomTabsStable() {
    #expect(AccountDetailLayout.macBottomTabs == [.transactions, .chart])
  }

  @Test("macOS pins a positions pane only when there are holdings")
  func macPinnedPositions() {
    #expect(AccountDetailLayout.macShowsPinnedPositions(hasPositions: true))
    #expect(!AccountDetailLayout.macShowsPinnedPositions(hasPositions: false))
  }

  // MARK: - hasNonHostHoldings (authoritative post-valuation)

  @Test("valuated input with a non-host row has holdings")
  func inputWithNonHostRow() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: aud)),
        ValuedPosition(
          instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 304, instrument: aud)),
      ],
      historicalValue: nil)
    #expect(
      AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [], hostCurrency: aud, positionsInput: input))
  }

  @Test("valuated host-only input has no holdings")
  func inputHostOnly() {
    let input = PositionsViewInput(
      title: "Everyday",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: aud))
      ],
      historicalValue: nil)
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [], hostCurrency: aud, positionsInput: input))
  }

  // MARK: - hasNonHostHoldings (pre-valuation raw heuristic)

  @Test("pre-valuation: multi-instrument raw positions have holdings")
  func rawMultiInstrument() {
    #expect(
      AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 200),
        ],
        hostCurrency: aud, positionsInput: nil))
  }

  @Test("pre-valuation: host-only, empty, and zero-qty raw positions have no holdings")
  func rawNoHoldings() {
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [Position(instrument: aud, quantity: 1_000)],
        hostCurrency: aud, positionsInput: nil))
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [], hostCurrency: aud, positionsInput: nil))
    #expect(
      !AccountDetailLayout.hasNonHostHoldings(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 0),
        ],
        hostCurrency: aud, positionsInput: nil))
  }
}
