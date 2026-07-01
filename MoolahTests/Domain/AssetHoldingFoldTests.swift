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

  @Test
  func multiChainAccountsYieldNilChainId() throws {
    let keys = ["10:native": "ethereum", "8453:native": "ethereum"]
    let rows = [
      ValuedPosition(
        instrument: eth(10), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 10),
      ValuedPosition(
        instrument: eth(8453), quantity: 2, unitPrice: nil, costBasis: nil, value: nil,
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
  func unwiredPositionFallsBackToInstrumentChain() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: nil)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.chainId == 1)
    #expect(holding.contributingChainIds == [1])
  }

  @Test
  func accountChainWinsOverInstrumentChain() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 10)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.chainId == 10)
    #expect(holding.contributingChainIds == [10])
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

  // MARK: - Chain caption suppression (design §5)

  /// A canonical/unified asset (e.g. ETH `1:native` mapped to "ethereum")
  /// must suppress its chain caption. The `id` (provider key "ethereum")
  /// differs from the contributing instrument id ("1:native"), which is the
  /// signal that identifies a unified holding.
  @Test
  func unifiedAssetSuppressesChainCaption() throws {
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: nil)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    #expect(holding.id == "ethereum")
    #expect(holding.contributingInstrumentIds == ["1:native"])
    #expect(holding.contributingChainNames.isEmpty)
    #expect(holding.chainSummaryLabel == nil)
    #expect(holding.chainAccessibilitySummary == nil)
  }

  /// A chain-scoped token with no provider mapping must keep its chain
  /// caption. Its `id` equals its instrument id — not a provider key —
  /// so the suppression guard does not fire.
  @Test
  func chainScopedNoKeyTokenKeepsChainCaption() throws {
    let token = Instrument.crypto(
      chainId: 137, contractAddress: "0xabc", symbol: "FOO", name: "Foo", decimals: 18)
    let rows = [
      ValuedPosition(
        instrument: token, quantity: 1, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: 137)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: [:], hostCurrency: aud).first)
    #expect(holding.id == "137:0xabc")
    #expect(holding.contributingChainNames == ["Polygon"])
    #expect(holding.chainSummaryLabel == "Polygon")
  }

  /// Regression guard (design §5): after Task 2, OP-ETH and Base-ETH mint as
  /// `1:native`. A multi-account group host coalesces them into one
  /// `ValuedPosition` with `accountChainId = nil`, so the fold computes
  /// `contributingChainIds = [1]` and would show "Ethereum" — misleading.
  /// Option 2 suppresses the chain caption for this unified/canonical asset.
  @Test
  func groupHostCoalescedUnifiedETHSuppressesChainCaption() throws {
    // Simulates what aggregatedGroupPositions + group host produce: one
    // 1:native position, accountChainId nil (group host has no single chain).
    let rows = [
      ValuedPosition(
        instrument: eth(1), quantity: 3, unitPrice: nil, costBasis: nil, value: nil,
        accountChainId: nil)
    ]
    let holding = try #require(
      AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud).first)
    // contributingChainIds is [1] from the instrument fallback — misleadingly
    // "Ethereum" — but chain caption must be suppressed for unified assets.
    #expect(holding.contributingChainIds == [1])
    #expect(
      holding.chainSummaryLabel == nil,
      "Unified canonical asset must suppress misleading chain caption (design §5)")
  }
}
