import Foundation
import Testing

@testable import Moolah

@Suite("CompositeTokenResolutionClient")
struct CompositeTokenResolutionClientTests {

  @Test
  func resolve_contractToken_findsCryptoCompareAndBinance() async throws {
    let ccCoinList = Data(
      """
      {
          "Data": {
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              }
          }
      }
      """.utf8)

    let binanceInfo = Data(
      """
      {
          "symbols": [
              { "symbol": "UNIUSDT", "baseAsset": "UNI", "quoteAsset": "USDT", "status": "TRADING" }
          ]
      }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(result.cryptocompareSymbol == "UNI")
    #expect(result.binanceSymbol == "UNIUSDT")
  }

  @Test
  func resolve_nativeToken_matchesBySymbol() async throws {
    let ccCoinList = Data(
      """
      {
          "Data": {
              "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
              "WBTC": { "Symbol": "WBTC", "CoinName": "Wrapped BTC", "SmartContractAddress": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" }
          }
      }
      """.utf8)

    let binanceInfo = Data(
      """
      {
          "symbols": [
              { "symbol": "BTCUSDT", "baseAsset": "BTC", "quoteAsset": "USDT", "status": "TRADING" }
          ]
      }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    let result = try await client.resolve(
      chainId: 0, contractAddress: nil, symbol: "BTC", isNative: true
    )
    #expect(result.cryptocompareSymbol == "BTC")
    #expect(result.binanceSymbol == "BTCUSDT")
  }

  @Test
  func resolve_unknownToken_returnsEmptyResult() async throws {
    let ccCoinList = Data(
      """
      { "Data": {} }
      """.utf8)

    let binanceInfo = Data(
      """
      { "symbols": [] }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
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

  @Test
  func resolve_matchesContractAddressRegardlessOfCase() async throws {
    // CoinList uses lowercase addresses; callers may pass checksummed (mixed-case).
    let ccCoinList = Data(
      """
      {
          "Data": {
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              }
          }
      }
      """.utf8)

    let binanceInfo = Data(
      """
      { "symbols": [] }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0x1F9840A85D5AF5BF1D1762F925BDADDC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(result.cryptocompareSymbol == "UNI")
  }

  /// Issue #790: a spam ERC-20 whose user-supplied ticker collides with a
  /// real token on Binance must NOT inherit that token's `<TICKER>USDT`
  /// pair. The resolver's contract-based providers (CryptoCompare's
  /// SmartContractAddress index, CoinGecko's `(platform, contract)`
  /// lookup) are the only authority for ERC-20 identity; ticker-only
  /// matches against Binance are forbidden.
  @Test
  func resolve_spamErc20WithCopiedTicker_doesNotInheritBinancePair() async throws {
    // CryptoCompare lists the legitimate OP contract on OP-mainnet. The
    // spam contract is intentionally absent.
    let ccCoinList = Data(
      """
      {
          "Data": {
              "OP": {
                  "Symbol": "OP",
                  "CoinName": "Optimism",
                  "SmartContractAddress": "0x4200000000000000000000000000000000000042"
              }
          }
      }
      """.utf8)

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
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    // The spam contract from the issue's repro wallet, sharing ticker
    // "OP" with the legitimate token.
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

    // Sanity: the legitimate contract still resolves cleanly.
    let real = try await client.resolve(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP",
      isNative: false
    )
    #expect(real.cryptocompareSymbol == "OP")
    #expect(real.binanceSymbol == "OPUSDT")
  }

  @Test
  func resolve_nativeOnDifferentChainsAreDistinct() async throws {
    // Resolving native tokens on two different chainIds should not conflate them —
    // the chainId combined with symbol scopes the lookup.
    let ccCoinList = Data(
      """
      {
          "Data": {
              "ETH": { "Symbol": "ETH", "CoinName": "Ethereum", "SmartContractAddress": "N/A" },
              "MATIC": { "Symbol": "MATIC", "CoinName": "Polygon", "SmartContractAddress": "N/A" }
          }
      }
      """.utf8)

    let binanceInfo = Data(
      """
      { "symbols": [] }
      """.utf8)

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
      exchangeInfoData: binanceInfo,
      coinGeckoApiKeyProvider: { nil }
    )

    let eth = try await client.resolve(
      chainId: 1, contractAddress: nil, symbol: "ETH", isNative: true
    )
    let matic = try await client.resolve(
      chainId: 137, contractAddress: nil, symbol: "MATIC", isNative: true
    )
    #expect(eth.cryptocompareSymbol == "ETH")
    #expect(matic.cryptocompareSymbol == "MATIC")
  }
}

/// Post-confirm CryptoCompare by-symbol path, exercised end-to-end via
/// `StubURLProtocol` for the CoinGecko round-trips. Separate suite so the
/// shared-handler reset can be scoped to a class with `deinit` without
/// disturbing the simpler in-process tests above.
@Suite("CryptoCompare post-confirm by symbol", .serialized)
final class PostConfirmBySymbolTests {
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

  /// CryptoCompare ships USDT as a primary, chain-agnostic entry with no
  /// `SmartContractAddress`. The contract-address index in step 1 of the
  /// resolver therefore can't find it. After CoinGecko confirms
  /// `(chainId, contract) → symbol="USDT"`, the by-symbol post-confirm
  /// must fill in `cryptocompareSymbol` so price fallback chains have
  /// more than just CoinGecko to rely on.
  @Test
  func resolve_usdtPostConfirmsCryptoCompareBySymbol() async throws {
    let ccCoinList = Data(
      """
      { "Data": { "USDT": { "Symbol": "USDT", "CoinName": "Tether" } } }
      """.utf8)
    let binanceInfo = Data(#"{ "symbols": [] }"#.utf8)
    stubAssetPlatforms(#"[{"id": "ethereum", "chain_identifier": 1, "name": "Ethereum"}]"#)
    stubContractLookup(
      platform: "ethereum",
      contract: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      json:
        #"{"id":"tether","symbol":"usdt","name":"Tether","detail_platforms":{"ethereum":{"decimal_place":6}}}"#
    )

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
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
    #expect(result.cryptocompareSymbol == "USDT")
    // USDT is the quote asset on Binance — USDTUSDT pair doesn't exist
    // and `binanceSymbol` must stay nil even after the post-confirm.
    #expect(result.binanceSymbol == nil)
  }

  /// Issue #790 safety: a spam ERC-20 whose user-supplied ticker
  /// collides with a real token must NOT inherit the legitimate token's
  /// CryptoCompare attribution via the post-confirm path. CoinGecko
  /// can't verify the spam contract (no listing on the chain at that
  /// address), so `resolvedSymbol` stays nil and the by-symbol fallback
  /// is gated off.
  @Test
  func resolve_spamErc20WithCopiedTicker_doesNotPostConfirmBySymbol() async throws {
    let ccCoinList = Data(
      """
      { "Data": { "USDT": { "Symbol": "USDT", "CoinName": "Tether" } } }
      """.utf8)
    let binanceInfo = Data(#"{ "symbols": [] }"#.utf8)
    stubAssetPlatforms(
      #"[{"id": "optimistic-ethereum", "chain_identifier": 10, "name": "Optimism"}]"#)
    // CoinGecko returns 200 with an "error" payload for an unknown
    // contract — `parseContractLookupResponse` then throws and the
    // resolver's catch block leaves `result.resolvedSymbol` nil, which
    // is the exact gating condition the post-confirm depends on.
    stubContractLookup(
      platform: "optimistic-ethereum",
      contract: "0xdeadbeef",
      json: #"{"error":"coin not found"}"#)

    let client = CompositeTokenResolutionClient(
      coinListData: ccCoinList,
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
