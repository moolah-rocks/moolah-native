import Foundation
import Testing

@testable import Moolah

@Suite("CryptoRegistration")
struct CryptoRegistrationTests {
  @Test
  func presetsDefaultToPriced() {
    for preset in CryptoRegistration.builtInPresets {
      #expect(preset.pricingStatus == .priced)
    }
  }

  /// The Polygon native preset must carry the post-rebrand provider ids: the
  /// MATIC→POL migration retired the `matic-network` CoinGecko id (now dead on
  /// CoinGecko and DefiLlama) and halted Binance's `MATICUSDT` pair (now
  /// `POLUSDT`). Pin the live ids so a regression to the stale ones is caught.
  @Test
  func polygonPresetUsesPostRebrandProviderIds() throws {
    let polygon = try #require(
      CryptoRegistration.builtInPresets.first { $0.instrument.id == "137:native" })
    #expect(polygon.mapping.coingeckoId == "polygon-ecosystem-token")
    #expect(polygon.mapping.binanceSymbol == "POLUSDT")
  }

  @Test
  func legacyRegistrationDecodesAsPriced() throws {
    let json = Data(
      """
      {"instrument":{"id":"1:native","kind":"cryptoToken","name":"Ethereum","decimals":18,"ticker":"ETH","chainId":1},"mapping":{"instrumentId":"1:native","coingeckoId":"ethereum","cryptocompareSymbol":"ETH","binanceSymbol":"ETHUSDT"}}
      """.utf8)
    let decoded = try JSONDecoder().decode(CryptoRegistration.self, from: json)
    #expect(decoded.pricingStatus == .priced)
  }

  @Test
  func explicitStatusRoundTrips() throws {
    let registration = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0x1234567890abcdef1234567890abcdef12345678",
        symbol: "WTF", name: "Spam Token", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0x1234567890abcdef1234567890abcdef12345678",
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil),
      pricingStatus: .spam
    )
    let data = try JSONEncoder().encode(registration)
    let decoded = try JSONDecoder().decode(CryptoRegistration.self, from: data)
    #expect(decoded.pricingStatus == .spam)
  }
}
