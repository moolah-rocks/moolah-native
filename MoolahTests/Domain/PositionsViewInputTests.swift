import Foundation
import Testing

@testable import Moolah

@Suite("PositionsViewInput")
struct PositionsViewInputTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let fixedTestDate = Date(timeIntervalSinceReferenceDate: 0)

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  @Test("totalValue sums all row values in host currency")
  func totalSumsRowValues() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: amount(11_325)),
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: amount(1_000)),
      ],
      historicalValue: nil
    )
    #expect(input.totalValue == amount(12_325))
  }

  @Test("totalValue is nil when any row's value is nil")
  func totalUnavailableOnFailure() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: amount(100)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: nil),
      ],
      historicalValue: nil
    )
    #expect(input.totalValue == nil)
  }

  @Test("totalGainLoss sums per-row gain/loss; rows without cost contribute 0")
  func totalGainLossSums() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(80), value: amount(100)),
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(50)),
      ],
      historicalValue: nil
    )
    #expect(input.totalGainLoss == amount(20))
  }

  @Test("showsPLPill is false when no row has cost basis")
  func plPillHiddenWhenNoCostBasis() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: nil
    )
    #expect(!input.showsPLPill)
  }

  @Test("showsPLPill is false when total is unavailable")
  func plPillHiddenWhenTotalUnavailable() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: nil)
      ],
      historicalValue: nil
    )
    #expect(!input.showsPLPill)
  }

  @Test("totalValue is zero (not nil) for empty positions")
  func totalValueEmptyPositions() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(input.totalValue == amount(0))
    #expect(input.totalGainLoss == amount(0))
    #expect(!input.showsPLPill)
    #expect(!input.showsGroupSubtotals)
  }

  @Test("showsPLPill is true when cost basis exists and total is available")
  func plPillVisibleWhenCostBasisAndTotal() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(input.showsPLPill)
  }

  @Test("showsGroupSubtotals is true only when more than one kind is present")
  func subtotalsRequireMultipleKinds() {
    let stockOnly = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(!stockOnly.showsGroupSubtotals)

    let mixed = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60)),
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60)),
      ],
      historicalValue: nil
    )
    #expect(mixed.showsGroupSubtotals)
  }

  @Test
  func assetHoldingsFoldCryptoUsingAssetKeyMap() {
    let eth1 = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let eth10 = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let aud = Instrument.AUD
    func amount(_ value: Decimal) -> InstrumentAmount {
      InstrumentAmount(quantity: value, instrument: aud)
    }
    let input = PositionsViewInput(
      title: "Wallet",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: eth1, quantity: 2, unitPrice: amount(4000),
          costBasis: amount(6000), value: amount(8000)),
        ValuedPosition(
          instrument: eth10, quantity: 1, unitPrice: amount(4000),
          costBasis: amount(3000), value: amount(4000)),
      ],
      historicalValue: nil,
      assetKeysByInstrumentId: ["1:native": "ethereum", "10:native": "ethereum"])
    let holdings = input.assetHoldings
    #expect(holdings.count == 1)
    #expect(holdings.first?.quantity == 3)
    #expect(holdings.first?.value == amount(12000))
  }

  @Test
  func assetHoldingsDefaultEmptyMapStandsAlone() {
    let eth1 = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let eth10 = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let aud = Instrument.AUD
    func amount(_ value: Decimal) -> InstrumentAmount {
      InstrumentAmount(quantity: value, instrument: aud)
    }
    let input = PositionsViewInput(
      title: "Wallet",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: eth1, quantity: 2, unitPrice: amount(4000),
          costBasis: amount(6000), value: amount(8000)),
        ValuedPosition(
          instrument: eth10, quantity: 1, unitPrice: amount(4000),
          costBasis: amount(3000), value: amount(4000)),
      ],
      historicalValue: nil)  // no map → no merge
    #expect(input.assetHoldings.count == 2)
  }

}
