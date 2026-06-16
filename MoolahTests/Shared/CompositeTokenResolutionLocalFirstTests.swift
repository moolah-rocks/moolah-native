import Foundation
import Testing

@testable import Moolah

/// Counting test double for `LocalContractResolver`. An actor so the call
/// count is race-free under the `Sendable` protocol requirement.
private actor StubLocalContractResolver: LocalContractResolver {
  private let match: LocalContractMatch?
  private(set) var calls = 0

  init(match: LocalContractMatch?) { self.match = match }

  func localContractMatch(chainId: Int, contractAddress: String) async -> LocalContractMatch? {
    calls += 1
    return match
  }
}

/// Local-first resolution: a token known to the bundled / cached catalog is
/// priced from local data, ahead of (and without) any network provider call.
@Suite("CompositeTokenResolutionClient local-first", .serialized)
final class CompositeTokenResolutionLocalFirstTests {
  deinit {
    StubURLProtocol.handlers = [:]
  }

  private func noHandlerNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  @Test("A catalog hit resolves the CoinGecko id from local data")
  func localHitResolvesId() async throws {
    let local = StubLocalContractResolver(
      match: LocalContractMatch(coingeckoId: "usd-coin", symbol: "USDC", name: "USDC"))
    let client = CompositeTokenResolutionClient(
      coinListData: Data(#"{"Data":{}}"#.utf8),
      exchangeInfoData: Data(#"{"symbols":[]}"#.utf8),
      coinGeckoApiKeyProvider: { nil },
      localResolver: local
    )

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      symbol: "USDC",
      isNative: false
    )

    #expect(result.coingeckoId == "usd-coin")
    #expect(result.resolvedSymbol == "USDC")
    #expect(result.hasAnyProviderId)
  }

  @Test("A catalog hit short-circuits ahead of any network call")
  func localHitSkipsNetwork() async throws {
    // No StubURLProtocol handlers are registered, so any outbound request
    // throws. The resolution must still succeed, proving no network was hit.
    let local = StubLocalContractResolver(
      match: LocalContractMatch(coingeckoId: "usd-coin", symbol: "USDC", name: "USDC"))
    let client = CompositeTokenResolutionClient(
      networking: noHandlerNetworking(),
      coinGeckoApiKeyProvider: { "" },
      localResolver: local
    )

    let result = try await client.resolve(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC",
      isNative: false
    )

    #expect(result.coingeckoId == "usd-coin")
    #expect(await local.calls == 1)
  }

  @Test("A native token bypasses the local contract lookup")
  func nativeBypassesLocal() async throws {
    let local = StubLocalContractResolver(match: nil)
    let client = CompositeTokenResolutionClient(
      coinListData: Data(#"{"Data":{}}"#.utf8),
      exchangeInfoData: Data(#"{"symbols":[]}"#.utf8),
      coinGeckoApiKeyProvider: { nil },
      localResolver: local
    )

    _ = try await client.resolve(
      chainId: 1, contractAddress: nil, symbol: "ETH", isNative: true)

    #expect(await local.calls == 0)
  }
}
