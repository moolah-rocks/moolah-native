import Foundation
import Testing

@testable import Moolah

/// In-memory `CryptoCompareSymbolLookup` returning canned answers without any
/// network or SQLite access, so a test can prove the resolver sources its
/// CryptoCompare data from the lookup rather than a live download.
private struct StubCryptoCompareLookup: CryptoCompareSymbolLookup {
  let contractSymbols: [String: String]
  let nativeSymbolSet: Set<String>
  let allSymbolSet: Set<String>

  func symbol(forContract address: String) async -> String? {
    contractSymbols[address.lowercased()]
  }
  func nativeSymbols() async -> Set<String> { nativeSymbolSet }
  func allSymbols() async -> Set<String> { allSymbolSet }
}

/// In-memory `BinancePairLookup` returning canned answers without any network
/// or SQLite access.
private struct StubBinanceLookup: BinancePairLookup {
  let pairs: Set<String>

  func hasUsdtPair(base symbol: String) async -> Bool {
    pairs.contains("\(symbol.uppercased())USDT")
  }
}

/// The injected caches are the source of CryptoCompare / Binance answers — the
/// resolver must never reach for the live coin-list / exchange-info downloads
/// when lookups are present. A networking with no registered handlers throws
/// on any request, so a successful resolution proves the network was bypassed.
@Suite("CompositeTokenResolutionClient cache-sourced", .serialized)
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

  @Test("Resolves a contract token purely from caches with no network")
  func resolvesFromCachesWithoutNetwork() async throws {
    let ccLookup = StubCryptoCompareLookup(
      contractSymbols: ["0x1f9840a85d5af5bf1d1762f925bdaddc4201f984": "UNI"],
      nativeSymbolSet: [],
      allSymbolSet: ["UNI"])
    let binance = StubBinanceLookup(pairs: ["UNIUSDT"])

    // No preloaded data and a networking that throws on any request: if the
    // resolver reached for the live coin-list or exchange-info download this
    // would throw rather than return a populated result.
    let client = CompositeTokenResolutionClient(
      networking: failingNetworking(),
      coinGeckoApiKeyProvider: { nil },
      cryptoCompareLookup: ccLookup,
      binanceLookup: binance)

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0x1F9840A85D5AF5BF1D1762F925BDADDC4201F984",
      symbol: nil,
      isNative: false)

    #expect(result.cryptocompareSymbol == "UNI")
    #expect(result.binanceSymbol == "UNIUSDT")
  }

  @Test("Resolves a native token purely from caches with no network")
  func resolvesNativeFromCachesWithoutNetwork() async throws {
    let ccLookup = StubCryptoCompareLookup(
      contractSymbols: [:], nativeSymbolSet: ["BTC"], allSymbolSet: ["BTC"])
    let binance = StubBinanceLookup(pairs: ["BTCUSDT"])

    let client = CompositeTokenResolutionClient(
      networking: failingNetworking(),
      coinGeckoApiKeyProvider: { nil },
      cryptoCompareLookup: ccLookup,
      binanceLookup: binance)

    let result = try await client.resolve(
      chainId: 0, contractAddress: nil, symbol: "BTC", isNative: true)

    #expect(result.cryptocompareSymbol == "BTC")
    #expect(result.binanceSymbol == "BTCUSDT")
  }
}
