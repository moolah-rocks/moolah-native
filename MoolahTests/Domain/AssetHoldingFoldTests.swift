import Foundation
import Testing

@testable import Moolah

@Suite
struct AssetHoldingFoldTests {
  private let aud = Instrument.AUD

  private func eth(_ chain: Int) -> Instrument {
    .crypto(chainId: chain, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  }

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  private let ethKeys = ["1:native": "ethereum", "10:native": "ethereum"]

  @Test
  func mergesEthAcrossChains() throws {
    let qty1 = try #require(Decimal(string: "11.36718"))
    let qty2 = try #require(Decimal(string: "1.58976"))
    let expectedQty = try #require(Decimal(string: "12.95694"))
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: qty1,
        unitPrice: amt(4000), costBasis: amt(30000), value: amt(45468), accountChainId: 1),
      ValuedPosition(
        instrument: eth(10), quantity: qty2,
        unitPrice: amt(4000), costBasis: amt(5000), value: amt(6359), accountChainId: 10),
    ]
    let holdings = AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud)
    #expect(holdings.count == 1)
    let holding = holdings[0]
    #expect(holding.id == "ethereum")
    #expect(holding.quantity == expectedQty)
    #expect(holding.value == amt(51827))
    #expect(holding.costBasis == amt(35000))
    #expect(holding.chainCount == 2)
    #expect(holding.chainId == nil)
    #expect(holding.contributingChainIds == [1, 10])
    #expect(Set(holding.contributingInstrumentIds) == ["1:native", "10:native"])
  }

  @Test
  func partialConversionFailureMakesValueNil() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000),
        value: amt(4000), accountChainId: 1),
      ValuedPosition(
        instrument: eth(10), quantity: 2, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 10),
    ]
    let holding = try #require(AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud).first)
    #expect(holding.quantity == 3)
    #expect(holding.value == nil)
    #expect(holding.costBasis == nil)
    #expect(holding.gainLoss == nil)
  }

  @Test
  func costBasisIndependentOfValue() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000),
        value: amt(4000)),
      ValuedPosition(
        instrument: eth(10), quantity: 2, unitPrice: nil, costBasis: amt(6000), value: nil),
    ]
    let holding = try #require(AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud).first)
    #expect(holding.value == nil)
    #expect(holding.costBasis == amt(9000))
    #expect(holding.gainLoss == nil)
  }

  @Test
  func unpricedTokenStandsAlone() {
    let token = Instrument.crypto(
      chainId: 1, contractAddress: "0xabc", symbol: "FOO", name: "Foo", decimals: 18)
    let rows = [
      ValuedPosition(
        instrument: token, quantity: 5, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 1)
    ]
    let holdings = AssetHolding.fold(rows, assetKeys: [:], hostCurrency: aud)
    #expect(holdings.count == 1)
    #expect(holdings[0].id == "1:0xabc")
    #expect(holdings[0].chainCount == 1)
  }

  @Test
  func stocksAndFiatNeverMerge() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let rows = [
      ValuedPosition(
        instrument: bhp, quantity: 100, unitPrice: amt(45), costBasis: amt(4000), value: amt(4500)),
      ValuedPosition(
        instrument: aud, quantity: 1000, unitPrice: nil, costBasis: nil, value: amt(1000)),
    ]
    let holdings = AssetHolding.fold(rows, assetKeys: [:], hostCurrency: aud)
    #expect(holdings.count == 2)
    #expect(Set(holdings.map(\.id)) == ["ASX:BHP.AX", "AUD"])
    #expect(holdings.first(where: { $0.id == "AUD" })?.currencyCode == "AUD")
  }

  @Test
  func singleChainPassthroughKeepsChainId() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000),
        value: amt(4000), accountChainId: 1)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.chainId == 1)
    #expect(holding.chainCount == 1)
    #expect(holding.id == "ethereum")
  }

  @Test
  func emptyInputYieldsNoHoldings() {
    #expect(AssetHolding.fold([], assetKeys: [:], hostCurrency: aud).isEmpty)
  }

  // MARK: - accountChainId-based chain derivation

  @Test
  func multiChainAccountsYieldNilChainId() throws {
    let eth8453 = Instrument.crypto(
      chainId: 8453, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let keys = ["10:native": "ethereum", "8453:native": "ethereum"]
    let rows = [
      ValuedPosition(
        instrument: eth(10), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 10),
      ValuedPosition(
        instrument: eth8453, quantity: 2, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 8453),
    ]
    let holding = try #require(AssetHolding.fold(rows, assetKeys: keys, hostCurrency: aud).first)
    #expect(holding.chainId == nil)
    #expect(holding.contributingChainIds == [10, 8453])
  }

  @Test
  func singleAccountChainPassesThrough() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 1)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.chainId == 1)
    #expect(holding.contributingChainIds == [1])
  }

  @Test
  func exchangePositionHasNoChain() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: nil)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.chainId == nil)
    #expect(holding.contributingChainIds.isEmpty)
  }

  @Test
  func sameInstrumentDeduped() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 1),
      ValuedPosition(
        instrument: eth(1), quantity: 2, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 1),
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.contributingInstrumentIds == ["1:native"])
  }

  @Test
  func derivesUnitPriceFromValueAndQuantity() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000),
        value: amt(4000)),
      ValuedPosition(
        instrument: eth(10), quantity: 2, unitPrice: amt(4000), costBasis: amt(6000),
        value: amt(8000)),
    ]
    let holding = try #require(AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud).first)
    #expect(holding.quantity == 3)
    #expect(holding.value == amt(12000))
    #expect(holding.unitPrice == amt(4000))
  }

  @Test
  func zeroQuantityYieldsNilUnitPrice() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(4000),
        value: amt(4000)),
      ValuedPosition(
        instrument: eth(10), quantity: -1, unitPrice: amt(4000), costBasis: amt(-4000),
        value: amt(-4000)),
    ]
    let holding = try #require(AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud).first)
    #expect(holding.quantity == 0)
    #expect(holding.unitPrice == nil)
  }
}
