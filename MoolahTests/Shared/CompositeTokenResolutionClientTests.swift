import Foundation
import Testing

@testable import Moolah

@Suite("CompositeTokenResolutionClient")
struct CompositeTokenResolutionClientTests {

  @Test
  func resolve_nativeToken_getsBinancePair() async throws {
    let binanceInfo = Data(
      """
      {
          "symbols": [
              { "symbol": "BTCUSDT", "baseAsset": "BTC", "quoteAsset": "USDT", "status": "TRADING" }
          ]
      }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    let result = try await client.resolve(
      chainId: 0, contractAddress: nil, symbol: "BTC", isNative: true
    )
    #expect(result.binanceSymbol == "BTCUSDT")
    #expect(result.cryptocompareSymbol == nil)
  }

  @Test
  func resolve_unknownToken_returnsEmptyResult() async throws {
    let binanceInfo = Data(
      """
      { "symbols": [] }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    let result = try await client.resolve(
      chainId: 999, contractAddress: "0xunknown", symbol: "NOPE", isNative: false
    )
    #expect(result.cryptocompareSymbol == nil)
    #expect(result.binanceSymbol == nil)
    #expect(result.coingeckoId == nil)
  }

  /// Issue #790: a spam ERC-20 whose user-supplied ticker collides with a
  /// real token on Binance must NOT inherit that token's `<TICKER>USDT`
  /// pair. CoinGecko's `(platform, contract)` lookup is the authority for
  /// ERC-20 identity; ticker-only matches against Binance are forbidden.
  @Test
  func resolve_spamErc20WithCopiedTicker_doesNotInheritBinancePair() async throws {
    // Binance lists OPUSDT — the legitimate trading pair the spam token
    // must not inherit.
    let binanceInfo = Data(
      """
      {
          "symbols": [
              { "symbol": "OPUSDT", "baseAsset": "OP", "quoteAsset": "USDT", "status": "TRADING" }
          ]
      }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    // The spam contract from the issue's repro wallet, sharing ticker
    // "OP" with the legitimate token. CoinGecko has not confirmed this
    // contract, so `resolvedSymbol` stays nil and Binance is blocked.
    let spam = try await client.resolve(
      chainId: 10,
      contractAddress: "0x7e087b1c173441f6c96b00231c1eab9e59f9a5a7",
      symbol: "OP",
      isNative: false
    )
    #expect(spam.cryptocompareSymbol == nil)
    #expect(spam.binanceSymbol == nil)
    #expect(spam.coingeckoId == nil)
    #expect(!spam.hasAnyProviderId)
  }
}

/// CoinGecko contract-based lookup paths, exercised end-to-end via
/// `StubURLProtocol` for the CoinGecko round-trips. Separate suite so the
/// shared-handler reset can be scoped to a class with `deinit` without
/// disturbing the simpler in-process tests above.
@Suite("CompositeTokenResolutionClient CoinGecko contract lookup", .serialized)
final class CoinGeckoContractLookupTests {
  deinit {
    StubURLProtocol.handlers = [:]
  }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: config)
    return NetworkingServices(session: session)
  }

  private func stubAssetPlatforms(_ json: String) {
    StubURLProtocol.handlers["api.coingecko.com:/api/v3/asset_platforms"] = { _ in
      (HTTPURLResponse.ok(etag: ""), Data(json.utf8))
    }
  }

  private func stubContractLookup(platform: String, contract: String, json: String) {
    let key = "api.coingecko.com:/api/v3/coins/\(platform)/contract/\(contract)"
    StubURLProtocol.handlers[key] = { _ in
      (HTTPURLResponse.ok(etag: ""), Data(json.utf8))
    }
  }

  /// CoinGecko contract lookup populates `coingeckoId` and sets
  /// `resolvedSymbol`. USDT is the quote asset on Binance, so no USDT-based
  /// pair exists and `binanceSymbol` stays nil.
  @Test
  func resolve_coinGeckoConfirmsContractAndPopulatesCoingeckoId() async throws {
    let binanceInfo = Data(#"{"symbols":[]}"#.utf8)
    stubAssetPlatforms(#"[{"id": "ethereum", "chain_identifier": 1, "name": "Ethereum"}]"#)
    stubContractLookup(
      platform: "ethereum",
      contract: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      json:
        #"{"id":"tether","symbol":"usdt","name":"Tether","detail_platforms":{"ethereum":{"decimal_place":6}}}"#
    )

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { "" },
      networking: makeNetworking()
    )
    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      symbol: "USDT",
      isNative: false
    )

    #expect(result.coingeckoId == "tether")
    #expect(result.cryptocompareSymbol == nil)
    // USDT is the quote asset on Binance — USDTUSDT pair doesn't exist
    // and `binanceSymbol` must stay nil.
    #expect(result.binanceSymbol == nil)
  }

  /// Happy path: CoinGecko confirms the ERC-20 contract (sets
  /// `resolvedSymbol`) and Binance lists the resulting `<SYMBOL>USDT` pair,
  /// so `binanceSymbol` is attributed. This exercises the complete
  /// CoinGecko → Binance flow that replaced the old CryptoCompare path.
  @Test
  func resolve_contractToken_findsCoinGeckoAndBinance() async throws {
    let binanceInfo = Data(
      #"""
      {"symbols":[{"symbol":"LINKUSDT","baseAsset":"LINK","quoteAsset":"USDT","status":"TRADING"}]}
      """#.utf8)
    stubAssetPlatforms(
      #"[{"id": "ethereum", "chain_identifier": 1, "name": "Ethereum"}]"#)
    stubContractLookup(
      platform: "ethereum",
      contract: "0x514910771af9ca656af840dff83e8264ecf986ca",
      json:
        #"{"id":"chainlink","symbol":"link","name":"Chainlink","detail_platforms":{"ethereum":{"decimal_place":18}}}"#
    )

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { "" },
      networking: makeNetworking()
    )
    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0x514910771af9ca656af840dff83e8264ecf986ca",
      symbol: "LINK",
      isNative: false
    )

    #expect(result.coingeckoId == "chainlink")
    #expect(result.resolvedSymbol == "LINK")
    #expect(result.binanceSymbol == "LINKUSDT")
    #expect(result.cryptocompareSymbol == nil)
  }

  /// Issue #790 safety: a spam ERC-20 whose user-supplied ticker
  /// collides with a real token must NOT inherit the legitimate token's
  /// Binance attribution. CoinGecko can't verify the spam contract,
  /// so `resolvedSymbol` stays nil and the Binance gate remains closed.
  @Test
  func resolve_spamErc20WithCopiedTicker_doesNotGetBinanceAfterCoinGeckoMiss()
    async throws
  {
    let binanceInfo = Data(
      #"{"symbols":[{"symbol":"USDTUSDT","baseAsset":"USDT","quoteAsset":"USDT","status":"TRADING"}]}"#
        .utf8)
    stubAssetPlatforms(
      #"[{"id": "optimistic-ethereum", "chain_identifier": 10, "name": "Optimism"}]"#)
    // CoinGecko returns 200 with an "error" payload for an unknown
    // contract — `parseContractLookupResponse` then throws and the
    // resolver's catch block leaves `result.resolvedSymbol` nil.
    stubContractLookup(
      platform: "optimistic-ethereum",
      contract: "0xdeadbeef",
      json: #"{"error":"coin not found"}"#)

    let client = CompositeTokenResolutionClient(
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { "" },
      networking: makeNetworking()
    )
    let result = try await client.resolve(
      chainId: 10,
      contractAddress: "0xdeadbeef",
      symbol: "USDT",
      isNative: false
    )

    #expect(result.coingeckoId == nil)
    #expect(result.cryptocompareSymbol == nil)
    #expect(result.binanceSymbol == nil)
    #expect(!result.hasAnyProviderId)
  }
}
