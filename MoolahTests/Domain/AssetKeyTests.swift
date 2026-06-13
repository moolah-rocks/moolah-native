import Testing

@testable import Moolah

@Suite
struct AssetKeyTests {
  @Test
  func coingeckoIdWins() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    #expect(mapping.assetKey == "ethereum")
  }

  @Test
  func fallsBackToCryptocompareWhenCoingeckoAbsent() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    #expect(mapping.assetKey == "ETH")
  }

  @Test
  func fallsBackToBinanceWhenCryptocompareAlsoAbsent() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: "ETHUSDT")
    #expect(mapping.assetKey == "ETHUSDT")
  }

  @Test
  func standsAloneWhenNoProviderId() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    #expect(mapping.assetKey == "1:0xabc")
  }

  @Test
  func mapMergesSameAssetAcrossChains() {
    let eth1 = CryptoRegistration(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum", cryptocompareSymbol: nil,
        binanceSymbol: nil))
    let eth10 = CryptoRegistration(
      instrument: .crypto(
        chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "10:native", coingeckoId: "ethereum", cryptocompareSymbol: nil,
        binanceSymbol: nil))
    let assetKeyMap = CryptoProviderMapping.assetKeys(from: [eth1, eth10])
    #expect(assetKeyMap["1:native"] == "ethereum")
    #expect(assetKeyMap["10:native"] == "ethereum")
  }
}
