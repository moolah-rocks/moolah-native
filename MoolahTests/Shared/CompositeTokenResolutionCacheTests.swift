import Foundation
import Testing

@testable import Moolah

/// In-memory `BinancePairLookup` returning canned answers without any network
/// or SQLite access.
private struct StubBinanceLookup: BinancePairLookup {
  let pairs: Set<String>

  func hasUsdtPair(base symbol: String) async -> Bool {
    pairs.contains("\(symbol.uppercased())USDT")
  }
}

/// The injected Binance cache is the source of Binance answers — the
/// resolver must never reach for the live exchange-info download when a
/// lookup is present. A networking with no registered handlers throws
/// on any request, so a successful resolution proves the network was bypassed.
@Suite("CompositeTokenResolutionClient Binance cache-sourced", .serialized)
final class CompositeTokenResolutionCacheTests {
  deinit {
    StubURLProtocol.handlers = [:]
  }

  /// A networking whose stub has zero handlers: every outbound request fails.
  private func failingNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  @Test("Resolves a native token from Binance cache with no network")
  func resolvesNativeFromBinanceCacheWithoutNetwork() async throws {
    let binance = StubBinanceLookup(pairs: ["BTCUSDT"])

    // No preloaded data and a networking that throws on any request: if the
    // resolver reached for the live exchange-info download this would throw
    // rather than return a populated result.
    let client = CompositeTokenResolutionClient(
      networking: failingNetworking(),
      coinGeckoApiKeyProvider: { nil },
      binanceLookup: binance)

    let result = try await client.resolve(
      chainId: 0, contractAddress: nil, symbol: "BTC", isNative: true)

    #expect(result.binanceSymbol == "BTCUSDT")
    #expect(result.cryptocompareSymbol == nil)
  }

  @Test("Unknown native token returns empty result from Binance cache with no network")
  func unknownNativeFromBinanceCacheWithoutNetwork() async throws {
    let binance = StubBinanceLookup(pairs: [])

    let client = CompositeTokenResolutionClient(
      networking: failingNetworking(),
      coinGeckoApiKeyProvider: { nil },
      binanceLookup: binance)

    let result = try await client.resolve(
      chainId: 0, contractAddress: nil, symbol: "NOPE", isNative: true)

    #expect(result.binanceSymbol == nil)
    #expect(result.cryptocompareSymbol == nil)
    #expect(!result.hasAnyProviderId)
  }
}
