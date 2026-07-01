import Foundation
import Testing

@testable import Moolah

@Suite("CryptoRegistration")
struct CryptoRegistrationTests {
  /// Regression test for the seeding gap identified in the PR4 final review.
  ///
  /// When a received L2 USDC leg (e.g. `10:0x0b2c…`) is canonicalized by
  /// `CanonicalInstrumentResolver` to mainnet USDC (`1:0xa0b8…`), leg
  /// resolution requires that canonical row to already exist in the local
  /// instrument store. Without the mainnet USDC preset, `instruments[id]` is
  /// nil and the fallback `Instrument.fiat(code: "1:0xa0b8…")` is returned —
  /// a bogus 2-decimal fiat that misscales amounts by ~10^4. Adding the preset
  /// ensures `registerBuiltInPresetsIfMissing` seeds the canonical row before
  /// any L2 leg is read, so the resolved instrument is a cryptoToken with 6
  /// decimals. This test fails if the USDC or USDT preset is removed.
  @Test("canonical mainnet USDC/USDT resolve as cryptoToken (6 decimals) after preset seed")
  func canonicalStablecoinsResolveAfterPresetSeed() async throws {
    let registry = StubInstrumentRegistry()
    await registry.registerBuiltInPresetsIfMissing()

    let instruments = try await registry.all()
    let instrumentMap = Dictionary(uniqueKeysWithValues: instruments.map { ($0.id, $0) })

    let mainnetUSDCId = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    let mainnetUSDTId = "1:0xdac17f958d2ee523a2206206994597c13d831ec7"

    let usdc = try #require(
      instrumentMap[mainnetUSDCId],
      "mainnet USDC (\(mainnetUSDCId)) not seeded by registerBuiltInPresetsIfMissing")
    #expect(usdc.kind == .cryptoToken, "USDC resolved as \(usdc.kind) — expected cryptoToken")
    #expect(usdc.decimals == 6, "USDC decimals: expected 6, got \(usdc.decimals)")

    let usdt = try #require(
      instrumentMap[mainnetUSDTId],
      "mainnet USDT (\(mainnetUSDTId)) not seeded by registerBuiltInPresetsIfMissing")
    #expect(usdt.kind == .cryptoToken, "USDT resolved as \(usdt.kind) — expected cryptoToken")
    #expect(usdt.decimals == 6, "USDT decimals: expected 6, got \(usdt.decimals)")
  }

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
