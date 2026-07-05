import Testing

@testable import Moolah

@Suite
struct AssetKeyTests {
  @Test
  func coingeckoIdWins() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT")
    #expect(mapping.assetKey == "ethereum")
  }

  @Test
  func fallsBackToBinanceWhenCoingeckoAbsent() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      binanceSymbol: "ETHUSDT")
    #expect(mapping.assetKey == "ETHUSDT")
  }

  @Test
  func standsAloneWhenNoProviderId() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil,
      binanceSymbol: nil)
    #expect(mapping.assetKey == "1:0xabc")
  }

  @Test
  func chainOneMapsToSharedAsset() {
    let map = CryptoRegistration.assetKeys(from: ethAcrossChains())
    #expect(map["1:native"] == "ethereum")
  }

  @Test
  func chainTenMapsToSharedAsset() {
    let map = CryptoRegistration.assetKeys(from: ethAcrossChains())
    #expect(map["10:native"] == "ethereum")
  }

  @Test
  func duplicateInstrumentIdLastWriteWins() {
    let first = CryptoRegistration(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        binanceSymbol: nil))
    let second = CryptoRegistration(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ether-renamed",
        binanceSymbol: nil))
    let map = CryptoRegistration.assetKeys(from: [first, second])
    #expect(map["1:native"] == "ether-renamed")
  }

  /// ETH registered on mainnet (chain 1) and Optimism (chain 10), both
  /// mapped to the shared `"ethereum"` asset key.
  private func ethAcrossChains() -> [CryptoRegistration] {
    [
      CryptoRegistration(
        instrument: .crypto(
          chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          binanceSymbol: nil)),
      CryptoRegistration(
        instrument: .crypto(
          chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: CryptoProviderMapping(
          instrumentId: "10:native", coingeckoId: "ethereum",
          binanceSymbol: nil)),
    ]
  }
}
